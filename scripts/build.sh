#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${ROOT_DIR}/build"
OUT_BIN="${OUT_DIR}/powermate-scroll"

mkdir -p "${OUT_DIR}"

xcrun swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macos13.0 \
  -whole-module-optimization \
  -framework SwiftUI \
  -framework AppKit \
  -framework ApplicationServices \
  -framework IOKit \
  -framework CoreGraphics \
  "${ROOT_DIR}"/src/*.swift \
  -o "${OUT_BIN}"

echo "Built ${OUT_BIN}"
