#!/usr/bin/env bash
# export-images.sh — Export each slide of an HTML presentation as a separate image
#
# Usage:
#   bash scripts/export-images.sh <path-to-html> [output-dir]
#
# Examples:
#   bash scripts/export-images.sh ./my-deck/index.html
#   bash scripts/export-images.sh ./presentation.html ./out/
#   bash scripts/export-images.sh ./presentation.html ./out/ --format jpeg
#   bash scripts/export-images.sh ./presentation.html --compact   # 1280x720
#   bash scripts/export-images.sh ./presentation.html --portrait  # 1080x1920 for TikTok / Xiaohongshu
#
# What this does:
#   1. Starts a local server (fonts and relative assets need HTTP)
#   2. Uses Playwright to capture each slide at the chosen viewport
#   3. Saves slide-001.png / slide-002.png / ... into the output directory
#
# Output is per-slide images — perfect for uploading to TikTok, Xiaohongshu,
# Instagram carousels, or anywhere you want each slide as a standalone post.
#
# The images are static snapshots. Animations are captured in their final state.
set -euo pipefail

# ─── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}ℹ${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# ─── Parse flags ──────────────────────────────────────────
#
# The output resolution is always VIEWPORT_W * DPR  by  VIEWPORT_H * DPR.
# Setting the viewport below the deck's mobile breakpoint (usually 600px)
# makes the deck's responsive CSS reflow content for the smaller frame —
# so portrait/square modes capture a real vertical layout, not a tiny
# landscape screenshot floating in letterbox bars.
#
# Defaults: 1920x1080 PNG   (full HD landscape — slide's native aspect)
# --compact:  1280x720      (HD landscape, smaller files)
# --portrait: 540x960 @ 2x  = 1080x1920 (9:16, mobile CSS active)
# --square:   540x540 @ 2x  = 1080x1080 (1:1,  mobile CSS active)
# --format:   png (default) or jpeg

VIEWPORT_W=1920
VIEWPORT_H=1080
DPR=1
FORMAT="png"
MODE="landscape"

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --compact)
            VIEWPORT_W=1280
            VIEWPORT_H=720
            shift
            ;;
        --portrait)
            # Render the deck IN a 9:16 phone viewport so responsive CSS
            # reflows it for vertical. DPR=2 doubles output to 1080x1920.
            VIEWPORT_W=540
            VIEWPORT_H=960
            DPR=2
            MODE="portrait"
            shift
            ;;
        --square)
            # Same idea but 1:1 — render at 540x540, captured at 1080x1080.
            VIEWPORT_W=540
            VIEWPORT_H=540
            DPR=2
            MODE="square"
            shift
            ;;
        --format)
            FORMAT="${2:-png}"
            if [[ "$FORMAT" != "png" && "$FORMAT" != "jpeg" ]]; then
                err "--format must be 'png' or 'jpeg' (got: $FORMAT)"
                exit 1
            fi
            shift 2
            ;;
        --format=*)
            FORMAT="${1#*=}"
            if [[ "$FORMAT" != "png" && "$FORMAT" != "jpeg" ]]; then
                err "--format must be 'png' or 'jpeg' (got: $FORMAT)"
                exit 1
            fi
            shift
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

# ─── Input validation ─────────────────────────────────────

if [[ $# -lt 1 ]]; then
    err "Usage: bash scripts/export-images.sh <path-to-html> [output-dir] [--compact|--portrait|--square] [--format png|jpeg]"
    err ""
    err "Examples:"
    err "  bash scripts/export-images.sh ./my-deck/index.html"
    err "  bash scripts/export-images.sh ./presentation.html ./out/"
    err "  bash scripts/export-images.sh ./presentation.html --portrait"
    err "  bash scripts/export-images.sh ./presentation.html --format jpeg"
    exit 1
fi

INPUT_HTML="$1"
if [[ ! -f "$INPUT_HTML" ]]; then
    err "File not found: $INPUT_HTML"
    exit 1
fi

# Resolve to absolute path
INPUT_HTML=$(cd "$(dirname "$INPUT_HTML")" && pwd)/$(basename "$INPUT_HTML")

# Output directory: use second positional arg or derive from input filename
if [[ $# -ge 2 ]]; then
    OUTPUT_DIR="$2"
else
    DECK_NAME=$(basename "$INPUT_HTML" .html)
    OUTPUT_DIR="$(dirname "$INPUT_HTML")/${DECK_NAME}-images"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      Export Slides to Images          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ─── Step 1: Check dependencies ───────────────────────────

info "Checking dependencies..."

if ! command -v npx &>/dev/null; then
    err "Node.js is required but not installed."
    err ""
    err "Install Node.js:"
    err "  macOS:   brew install node"
    err "  or visit https://nodejs.org and download the installer"
    exit 1
fi

ok "Node.js found"

# ─── Step 2: Build the export script ──────────────────────

TEMP_DIR=$(mktemp -d)
TEMP_SCRIPT="$TEMP_DIR/export-images.mjs"

SERVE_DIR=$(dirname "$INPUT_HTML")
HTML_FILENAME=$(basename "$INPUT_HTML")

cat > "$TEMP_SCRIPT" << 'EXPORT_SCRIPT'
// export-images.mjs — Capture each slide as a standalone image.
//
// 1. Starts a local HTTP server (fonts/assets need HTTP)
// 2. Loads the deck in headless Chromium at the chosen viewport and DPR
// 3. Walks every .slide, forces .reveal animations to their final state
// 4. Screenshots each slide at viewport_w*dpr by viewport_h*dpr pixels
//
// For portrait/square modes the viewport is set narrow enough that the
// deck's responsive CSS reflows for mobile (usually <=600px). DPR=2
// then doubles the output to a retina-sharp 1080-wide image.

import { chromium } from 'playwright';
import { createServer } from 'http';
import { readFileSync, mkdirSync } from 'fs';
import { join, extname } from 'path';

const SERVE_DIR  = process.argv[2];
const HTML_FILE  = process.argv[3];
const OUT_DIR    = process.argv[4];
const VP_W       = parseInt(process.argv[5]) || 1920;
const VP_H       = parseInt(process.argv[6]) || 1080;
const DPR        = parseFloat(process.argv[7]) || 1;
const FORMAT     = (process.argv[8] || 'png').toLowerCase();

// ─── Static file server ───────────────────────────────────

const MIME_TYPES = {
  '.html': 'text/html', '.css': 'text/css', '.js': 'application/javascript',
  '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp',
  '.woff': 'font/woff', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
};

const server = createServer((req, res) => {
  const decodedUrl = decodeURIComponent(req.url);
  const filePath = join(SERVE_DIR, decodedUrl === '/' ? HTML_FILE : decodedUrl);
  try {
    const content = readFileSync(filePath);
    const ext = extname(filePath).toLowerCase();
    res.writeHead(200, { 'Content-Type': MIME_TYPES[ext] || 'application/octet-stream' });
    res.end(content);
  } catch {
    res.writeHead(404);
    res.end('Not found');
  }
});

const port = await new Promise((resolve) => {
  server.listen(0, () => resolve(server.address().port));
});

console.log(`  Local server on port ${port}`);

// ─── Open deck + count slides ─────────────────────────────

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: VP_W, height: VP_H },
  deviceScaleFactor: DPR,
});

await page.goto(`http://localhost:${port}/`, { waitUntil: 'networkidle' });
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(1500);

const slideCount = await page.evaluate(() => document.querySelectorAll('.slide').length);

console.log(`  Found ${slideCount} slides`);

if (slideCount === 0) {
  console.error('  ERROR: No .slide elements found.');
  console.error('  Make sure your HTML uses <section class="slide"> or <div class="slide">.');
  await browser.close(); server.close(); process.exit(1);
}

mkdirSync(OUT_DIR, { recursive: true });

// ─── Capture each slide ───────────────────────────────────

const rawPaths = [];
const ext = FORMAT === 'jpeg' ? 'jpg' : 'png';

// Mark every slide as .visible upfront so .reveal transitions don't
// leave delayed-staggered items invisible at screenshot time. Force
// each .reveal element's inline styles to their final state too —
// belt + suspenders against any preset that uses different selectors.
await page.evaluate(() => {
  document.querySelectorAll('.slide').forEach(s => s.classList.add('visible'));
  document.querySelectorAll('.reveal').forEach(el => {
    el.style.opacity = '1';
    el.style.transform = 'none';
    el.style.visibility = 'visible';
    el.style.filter = 'none';
  });
});

// Let layout settle after the bulk style change.
await page.waitForTimeout(400);

for (let i = 0; i < slideCount; i++) {
  // Scroll the target slide into view. Scroll-snap will lock it to
  // the top of the viewport. We don't hide siblings — that breaks
  // layout in decks that size grids relative to ancestor heights.
  await page.evaluate((index) => {
    const slides = document.querySelectorAll('.slide');
    slides[index]?.scrollIntoView({ behavior: 'instant', block: 'start' });
    slides.forEach((s, idx) => s.classList.toggle('active', idx === index));
    if (window.presentation && typeof window.presentation.goToSlide === 'function') {
      window.presentation.goToSlide(index);
    }
  }, i);

  // Wait for scroll/snap to complete.
  await page.waitForTimeout(250);

  const filename = `slide-${String(i + 1).padStart(3, '0')}.${ext}`;
  const outPath = join(OUT_DIR, filename);

  const shotOpts = {
    path: outPath,
    fullPage: false,
    type: FORMAT,
  };
  if (FORMAT === 'jpeg') shotOpts.quality = 92;

  await page.screenshot(shotOpts);
  rawPaths.push(outPath);
  console.log(`  Captured ${filename}`);
}

await browser.close();
server.close();

console.log(`  ✓ ${rawPaths.length} image(s) written to: ${OUT_DIR}`);
EXPORT_SCRIPT

# ─── Step 3: Install Playwright in temp dir ───────────────

info "Setting up Playwright (headless browser for screenshots)..."
info "This may take a moment on first run..."
echo ""

cd "$TEMP_DIR"

cat > "$TEMP_DIR/package.json" << 'PKG'
{ "name": "slide-export", "private": true, "type": "module" }
PKG

npm install playwright &>/dev/null || {
    err "Failed to install Playwright."
    err "Try running: npm install playwright"
    rm -rf "$TEMP_DIR"
    exit 1
}

npx playwright install chromium 2>/dev/null || {
    err "Failed to install Chromium browser for Playwright."
    err "Try running manually: npx playwright install chromium"
    rm -rf "$TEMP_DIR"
    exit 1
}
ok "Playwright ready"
echo ""

# ─── Step 4: Run the export ───────────────────────────────

OUTPUT_W=$((VIEWPORT_W * DPR))
OUTPUT_H=$((VIEWPORT_H * DPR))

if [[ "$MODE" == "portrait" ]]; then
    info "Mode: portrait — viewport ${VIEWPORT_W}x${VIEWPORT_H} @ ${DPR}x = ${OUTPUT_W}x${OUTPUT_H} ${FORMAT}"
    info "  (deck's responsive CSS reflows for mobile viewport)"
elif [[ "$MODE" == "square" ]]; then
    info "Mode: square — viewport ${VIEWPORT_W}x${VIEWPORT_H} @ ${DPR}x = ${OUTPUT_W}x${OUTPUT_H} ${FORMAT}"
    info "  (deck's responsive CSS reflows for mobile viewport)"
else
    info "Mode: landscape — ${OUTPUT_W}x${OUTPUT_H} ${FORMAT}"
fi

info "Exporting..."
echo ""

node "$TEMP_SCRIPT" "$SERVE_DIR" "$HTML_FILENAME" "$OUTPUT_DIR" "$VIEWPORT_W" "$VIEWPORT_H" "$DPR" "$FORMAT" || {
    err "Image export failed."
    rm -rf "$TEMP_DIR"
    exit 1
}

# ─── Step 5: Cleanup and success ──────────────────────────

rm -rf "$TEMP_DIR"

# Count actual output files
IMAGE_COUNT=$(find "$OUTPUT_DIR" -maxdepth 1 -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) | wc -l | xargs)
TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1 | xargs)

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
ok "Images exported successfully!"
echo ""
echo -e "  ${BOLD}Folder:${NC} $OUTPUT_DIR"
echo -e "  ${BOLD}Files:${NC}  $IMAGE_COUNT image(s)"
echo -e "  ${BOLD}Size:${NC}   $TOTAL_SIZE"
echo ""
case "$MODE" in
    portrait)
        echo "  Ready for TikTok, Reels, Xiaohongshu vertical posts."
        ;;
    square)
        echo "  Ready for Instagram square posts, Xiaohongshu 1:1 carousels."
        ;;
    *)
        echo "  Ready for blog headers, carousel posts, slide previews."
        echo "  Use --portrait for 9:16 (TikTok / Reels) or --square for 1:1 (IG / RedNote)."
        ;;
esac
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""

# Open the output folder so the user can immediately see the results
if command -v open &>/dev/null; then
    open "$OUTPUT_DIR"
elif command -v xdg-open &>/dev/null; then
    xdg-open "$OUTPUT_DIR"
fi
