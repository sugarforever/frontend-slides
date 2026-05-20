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
# Defaults: 1920x1080 PNG (full HD landscape — slide's native aspect)
# --compact:  1280x720  (HD landscape, smaller files)
# --portrait: 1080x1920 (9:16 vertical canvas; slide centered with letterboxing)
# --square:   1080x1080 (1:1 canvas;       slide centered with letterboxing)
# --format:   png (default) or jpeg

VIEWPORT_W=1920
VIEWPORT_H=1080
CANVAS_W=0       # 0 = no canvas wrap (output = raw screenshot)
CANVAS_H=0
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
            # Capture at native 1920x1080, then wrap into a 1080x1920 canvas
            CANVAS_W=1080
            CANVAS_H=1920
            MODE="portrait"
            shift
            ;;
        --square)
            CANVAS_W=1080
            CANVAS_H=1080
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
// 2. Loads the deck in headless Chromium at the chosen viewport
// 3. Walks every .slide, forces .reveal animations to their final state
// 4. Screenshots each slide
// 5. (Optional) Wraps each capture in a vertical/square canvas for socials

import { chromium } from 'playwright';
import { createServer } from 'http';
import { readFileSync, mkdirSync } from 'fs';
import { join, extname } from 'path';

const SERVE_DIR  = process.argv[2];
const HTML_FILE  = process.argv[3];
const OUT_DIR    = process.argv[4];
const VP_W       = parseInt(process.argv[5]) || 1920;
const VP_H       = parseInt(process.argv[6]) || 1080;
const CANVAS_W   = parseInt(process.argv[7]) || 0;
const CANVAS_H   = parseInt(process.argv[8]) || 0;
const FORMAT     = (process.argv[9] || 'png').toLowerCase();

const WRAP = CANVAS_W > 0 && CANVAS_H > 0;

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
const page = await browser.newPage({ viewport: { width: VP_W, height: VP_H } });

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

for (let i = 0; i < slideCount; i++) {
  // Show the target slide, hide the others.
  await page.evaluate((index) => {
    const slides = document.querySelectorAll('.slide');
    slides.forEach((slide, idx) => {
      if (idx === index) {
        slide.style.display = '';
        slide.style.opacity = '1';
        slide.style.visibility = 'visible';
        slide.style.position = 'relative';
        slide.style.transform = 'none';
        slide.classList.add('active');
      } else {
        slide.style.display = 'none';
        slide.classList.remove('active');
      }
    });
    if (window.presentation && typeof window.presentation.goToSlide === 'function') {
      window.presentation.goToSlide(index);
    }
    slides[index]?.scrollIntoView({ behavior: 'instant' });
  }, i);

  await page.waitForTimeout(300);

  // Force every .reveal in the active slide to its final visible state —
  // we want the FULL animated layout, not the pre-animation snapshot.
  await page.evaluate((index) => {
    const slides = document.querySelectorAll('.slide');
    const current = slides[index];
    if (!current) return;
    current.classList.add('visible');
    current.querySelectorAll('.reveal').forEach(el => {
      el.style.opacity = '1';
      el.style.transform = 'none';
      el.style.visibility = 'visible';
    });
  }, i);

  await page.waitForTimeout(200);

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

// ─── Optional: wrap each capture in a portrait/square canvas ───
// We do this in-browser by loading a tiny HTML page that draws the
// screenshot centered on the target canvas — avoids needing a native
// image library like sharp/imagemagick.

if (WRAP) {
  console.log(`  Wrapping to ${CANVAS_W}x${CANVAS_H} canvas (${FORMAT})...`);

  const wrapBrowser = await chromium.launch();
  const wrapPage = await wrapBrowser.newPage({
    viewport: { width: CANVAS_W, height: CANVAS_H },
  });

  // Probe the deck's body background — gives us a sensible fill color so
  // letterbox bars feel like the deck instead of pure black.
  const bgColor = await (async () => {
    const probe = await wrapBrowser.newPage({ viewport: { width: VP_W, height: VP_H } });
    await probe.goto(`http://localhost:${port}/`, { waitUntil: 'networkidle' });
    const c = await probe.evaluate(() => {
      const bg = getComputedStyle(document.body).backgroundColor;
      return bg && bg !== 'rgba(0, 0, 0, 0)' ? bg : '#0a0a0a';
    });
    await probe.close();
    return c;
  })();

  for (const p of rawPaths) {
    const imgData = readFileSync(p).toString('base64');
    const mime = FORMAT === 'jpeg' ? 'image/jpeg' : 'image/png';
    const html = `<!DOCTYPE html><html><head><style>
      html, body { margin: 0; padding: 0; width: ${CANVAS_W}px; height: ${CANVAS_H}px; background: ${bgColor}; overflow: hidden; }
      .frame { width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }
      img { max-width: 100%; max-height: 100%; object-fit: contain; display: block; }
    </style></head><body><div class="frame"><img src="data:${mime};base64,${imgData}" /></div></body></html>`;

    await wrapPage.setContent(html, { waitUntil: 'load' });

    const shotOpts = { path: p, fullPage: false, type: FORMAT };
    if (FORMAT === 'jpeg') shotOpts.quality = 92;
    await wrapPage.screenshot(shotOpts);
  }

  await wrapBrowser.close();
}

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

if [[ "$MODE" == "portrait" ]]; then
    info "Mode: portrait — captures at ${VIEWPORT_W}x${VIEWPORT_H}, wraps into ${CANVAS_W}x${CANVAS_H} canvas"
elif [[ "$MODE" == "square" ]]; then
    info "Mode: square — captures at ${VIEWPORT_W}x${VIEWPORT_H}, wraps into ${CANVAS_W}x${CANVAS_H} canvas"
else
    info "Mode: landscape — ${VIEWPORT_W}x${VIEWPORT_H} ${FORMAT}"
fi

info "Exporting..."
echo ""

node "$TEMP_SCRIPT" "$SERVE_DIR" "$HTML_FILENAME" "$OUTPUT_DIR" "$VIEWPORT_W" "$VIEWPORT_H" "$CANVAS_W" "$CANVAS_H" "$FORMAT" || {
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
