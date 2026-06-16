#!/bin/bash
# Wasm5: WasmCart's SDL3 console shell (Embedded Swift kit), but carts play in a
# WKWebView (Canvas2D/browser) instead of WAMR. The AppKit/WebKit/HTTP work lives in
# webview-shim.m (full Cocoa), linked into the Embedded-Swift host over a C ABI.
# Reuses WasmCart's vendored static SDL3.
set -euo pipefail
cd "$(dirname "$0")"
KIT="${KIT:-$(cd ../SuperBox64Kit && pwd)}"
WC="$(cd ../WasmCart && pwd)"
[ -f "$WC/vendor/libSDL3.a" ] || { echo "ERROR: build WasmCart first (need $WC/vendor/libSDL3.a)"; exit 1; }

# the Cocoa/WebKit shim — compiled with the real SDK (NOT Embedded Swift)
clang -c -fobjc-arc -O2 webview-shim.m -o webview-shim.o

GAME_SRC="$PWD/Sources" \
GAME_MAIN="$PWD/host-main.swift" \
OUT="$PWD/Wasm5" \
SDL_STATIC_A="$WC/vendor/libSDL3.a" \
EXTRA_OBJS="$PWD/webview-shim.o" \
EXTRA_LIBS="-framework WebKit -framework Cocoa -liconv" \
  "$KIT/native/build-native-game.sh"

echo "✓ Wasm5"
echo "run:  ./Wasm5     (put web-build carts — a dir or .zip with index.html — in ./carts/)"
