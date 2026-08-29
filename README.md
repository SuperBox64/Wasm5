# Wasm5

**The webview console.** WasmCart's SDL3 console shell — but instead of running carts through WAMR, Wasm5 plays each cart's **web build** inside a `WKWebView` overlaid on the SDL window: the real Canvas2D + browser-WebAssembly stack, at full fidelity. SDL3 keystrokes are forwarded into the cart as synthetic DOM `KeyboardEvent`s.

> Same picker UI as [WasmCart](../WasmCart). Same carts. Different runtime: a browser, not an interpreter.

---

## What is this?

Wasm5 is the **sister console** to [WasmCart](../WasmCart). The two share one cartridge-picker shell — a [SuperBox64Kit](../SuperBox64Kit) `SKScene` compiled as **Embedded Swift** and rendered through SDL3 — but they diverge entirely on how they *play* a cart:

| | how a cart runs | renderer |
|---|---|---|
| **WasmCart** | the cart's `.wasm`/`.aot` through WAMR (interpreter or wamrc AOT) | SDL3 + Metal (native KitABI backend) |
| **Wasm5** | the cart's **WEB build** (`index.html` + `runtime.js` + `.wasm` + assets) in a `WKWebView` | **Canvas2D inside WebKit** (browser stack) |

So a Wasm5 cart is not a re-implementation of the browser — it *is* the browser. The cart loads the exact `runtime.js` Canvas2D host from [WasmKit](../WasmKit), fulfilling the same KitABI imports it would on a real web page: resolution-independent SVG, color emoji, audio, 60 fps. The cart's WEB build is served over a localhost HTTP server (`python3 -m http.server` on `127.0.0.1:52900`) so `fetch()` and `WebAssembly.instantiate` see correct MIME types and no `file://` CORS issues.

The shell UI still draws with SDL3+Metal; only the cart pane is WebKit.

### The keyboard problem (why this repo exists)

When WebKit is linked into the process, **SDL3's macOS keyboard path stops working** — the mouse still reaches SDL's content view, but keystrokes never do. Wasm5's entire input design is the workaround:

- A single **app-wide `NSEvent` local key monitor** intercepts every key-down/up.
- **No cart up (shell):** nav keys are translated to SFML codes and pushed straight into the kit's event queue (bypassing SDL's broken path).
- **Cart up (webview):** keys are injected into the cart's JS as synthetic `KeyboardEvent`s via `evaluateJavaScript` — dispatched on both `window` and `document`, focus-independent, because `runtime.js` listens on `e.code`.
- `CTRL+ESC` ejects the webview back to the shell; `CMD+Q` quits. Both are grabbed by the monitor even while the webview owns the keyboard.

The host itself is **platform-agnostic over a 7-function C ABI**; all the AppKit/WebKit/HTTP work lives in per-OS shims (macOS Obj-C `webview-shim.m`, Linux WebKitGTK `webview-shim-linux.c`, Windows WebView2 `webview-shim-win.cpp`).

---

## Where Wasm5 sits in the constellation

```
                         ONE game source  (UFO-Emoji-Arcade: GameScene.swift et al.)
                                        │
                                        ▼
                         ┌──────────────────────────────┐
                         │        SuperBox64Kit          │  drop-in SpriteKit for Embedded/wasm Swift
                         │  SpriteKit emul · KitABI       │  + SDL3 backend · Box2D v3 · reSVG vector
                         └──────────────────────────────┘
                                        │ compiles one tree three ways
            ┌───────────────────────────┼────────────────────────────────┐
            ▼                           ▼                                 ▼
   full-Swift wasm32           Embedded-Swift wasm32              Embedded-Swift native
   (~4.18 MB)                  (~688 KB)                          (arm64 single binary)
            │                           │                                 │
            ▼                           ▼                                 ▼
   ┌─────────────────┐       browser: WasmKit runtime.js          SDL3 + Metal direct
   │     WasmKit     │  ←──  Canvas2D host, fulfils KitABI
   │ runtime.js +    │       (index.html + embedded.html)
   │   Canvas2D      │
   └─────────────────┘
            │  the SAME web build is consumed by two native consoles:
            │
            ├───────────────► ┌─────────────┐   .wasm / .aot through WAMR (interp + wamrc AOT)
            │                 │  WasmCart   │   SDL3 + Metal, native KitABI backend
            │                 └─────────────┘
            │
            └───────────────► ┌─────────────┐   ★ YOU ARE HERE
                              │   Wasm5     │   SDL3 shell + WKWebView cart
                              └─────────────┘   real runtime.js/Canvas2D in WebKit,
                                                SDL keystrokes → synthetic DOM KeyboardEvents
```

Wasm5 reuses WasmCart's vendored static `libSDL3.a` and the kit's build driver; it adds nothing to the cart format. A cart is just its web build — the same `runtime.js` + `.wasm` from [WasmKit](../WasmKit) and the [UFO-Emoji-Arcade](../UFO-Emoji-Arcade) web pipeline.

---

## Features

- **Reuses WasmCart's SDL3 console shell verbatim** — a SuperBox64Kit `SKScene` rendered through SDL3, compiled as Embedded Swift — for the cartridge picker (slot label `WASMFIVE`).
- **Plays carts in a `WKWebView` overlaid on the SDL window:** runs the cart's real web build on the genuine Canvas2D + browser-WebAssembly stack instead of WAMR.
- **Serves each cart over localhost** (`python3 -m http.server` on `127.0.0.1:52900`) so `fetch()`/`WebAssembly` load with correct MIME types and no `file://` CORS issues.
- **Accepts a directory *or* a `.zip`:** `resolveWebDir` unzips (`/usr/bin/unzip`) and walks one folder deep to find `index.html`.
- **SDL3 keystrokes → synthetic DOM `KeyboardEvent`s** via `evaluateJavaScript` — focus-independent, dispatched on both `window` and `document` (`runtime.js` listens on `e.code`).
- **One app-wide `NSEvent` key monitor**, mode-switched: shell nav → SFML codes into the kit queue; cart keys → injected into the cart's JS.
- **`CTRL+ESC` ejects** the webview back to the shell; **`CMD+Q` quits** — both grabbed by the monitor even while the webview owns the keyboard.
- **Carts folder auto-scanned and re-scanned** (~every 180 frames); drag-and-drop a cart at any time; **OPEN FILE** dialog via `SDL_ShowOpenFileDialog`.
- **Bundled vector-segment `ShellFont`** (10×14 line-segment glyphs) draws the menu with the same vector lettering as the games it hosts.
- **Cross-platform shims behind one C ABI:** macOS (`WKWebView`), Linux (WebKitGTK reparented into the X11 window), Windows (WebView2 child of the HWND). *Linux/Windows shims present but untested on the macOS host.*
- **Forces a regular foreground/key state on launch** (`wasm5_activate`) because linking WebKit/Cocoa can otherwise leave the SDL window un-activated and swallow keystrokes.
- **Persists the emoji-mode preference** to the kit pref store (`store.tsv` under `SDL_GetPrefPath`) for shell parity with WasmCart — though emoji-mode has **no effect** on webview carts (the browser renders emoji with its own system font; the toggle is intentionally dropped here).

---

## Build × runtime permutations

Wasm5 is **one host** in a 5-repo constellation that runs **one game source** through seven real build × runtime permutations. Wasm5 owns the last row.

| # | Build (wasm flavor) | Host / runtime | Renderer | Repo |
|---|---|---|---|---|
| 1 | None — Apple-native SpriteKit | Apple SpriteKit (UIKit/AppKit) | Metal + UIKit | [UFO-Emoji-Arcade](../UFO-Emoji-Arcade) |
| 2 | Full-Swift `wasm32-unknown-wasip1` (~4.18 MB) | `runtime.js` in a browser | Canvas2D | [WasmKit](../WasmKit) |
| 3 | Embedded-Swift `wasm32` (~688 KB) | `runtime-embedded-min.js` in a browser | Canvas2D | [WasmKit](../WasmKit) |
| 4 | None — Embedded-Swift native (arm64) | SDL3 backend, single binary | SDL3 + Metal | [SuperBox64Kit](../SuperBox64Kit) |
| 5 | `.wasm` cart | **WAMR interpreter** (WasmCart) | SDL3 + Metal | [WasmCart](../WasmCart) |
| 6 | `.aot` cart (wamrc AOT) | **WAMR AOT** (WasmCart) | SDL3 + Metal | [WasmCart](../WasmCart) |
| 7 | The **web build** (unchanged) | **`WKWebView`** (Wasm5) | **Canvas2D in WebKit** + SDL3/Metal shell | **Wasm5 (this repo)** |

Permutation 7 is *"the real browser stack inside the native console."* The cart binary is byte-for-byte the same web build that ships at [UFO-Emoji-Arcade](../UFO-Emoji-Arcade)'s site — Wasm5 just hosts it locally inside WebKit instead of on a web page.

---

## Build & Run

### Prerequisites

- macOS (arm64). The shim is compiled with the **real macOS SDK** (full Cocoa/WebKit), *not* Embedded Swift.
- Sibling repos checked out beside this one:
  - `../SuperBox64Kit` — provides `native/build-native-game.sh` (the compiler driver), the `Kit`/`kitHost` API, and the Embedded-Swift framework modules.
  - `../WasmCart` — **must be built first**, so its vendored static archive `../WasmCart/vendor/libSDL3.a` exists. `build.sh` aborts otherwise.
- Swift toolchain `swift-6.3.2-RELEASE.xctoolchain` (pinned in the kit's build script; override with `SWIFTC=`).
- `python3` and `/usr/bin/unzip` on `PATH` (runtime, for serving / unzipping carts).

### Build

```bash
# 1) build WasmCart first (produces ../WasmCart/vendor/libSDL3.a)
cd ../WasmCart && ./build.sh

# 2) build Wasm5
cd ../Wasm5 && ./build.sh
```

What `build.sh` does:

```bash
# clang-compile the Cocoa/WebKit shim with the real SDK (NOT Embedded Swift)
clang -c -fobjc-arc -O2 webview-shim.m -o webview-shim.o

# then invoke the kit's native game builder with the shell as the game source
GAME_SRC="$PWD/Sources" \
GAME_MAIN="$PWD/host-main.swift" \
OUT="$PWD/Wasm5" \
SDL_STATIC_A="../WasmCart/vendor/libSDL3.a" \
EXTRA_OBJS="$PWD/webview-shim.o" \
EXTRA_LIBS="-framework WebKit -framework Cocoa -liconv" \
  ../SuperBox64Kit/native/build-native-game.sh
```

- `KIT` path is overridable (`KIT=/path/to/SuperBox64Kit ./build.sh`); defaults to `../SuperBox64Kit`.
- The kit build targets `arm64-apple-macos14`, Embedded Swift `-wmo -Osize`, and pins `SWIFTC` to the 6.3.2 toolchain.

### Run

```bash
./Wasm5
```

Put web-build carts in `./carts/` — a **directory** or a **`.zip`** containing `index.html`. Override the carts directory with `WASMCART_CARTS`:

```bash
WASMCART_CARTS=/path/to/my/carts ./Wasm5
```

> A sample cart is bundled: `carts/ufoemoji.zip` (the UFO Emoji web build — `index.html` + `runtime.js` + `ufoemoji.wasm` + assets, plus an embedded `ufoemoji-embedded.wasm` variant; 626×352 logical canvas). The shim unzips it to a temp dir at runtime; only the `.zip` is tracked.

### Controls

| Context | Key | Action |
|---|---|---|
| Shell | `↑` / `↓` | Select cart |
| Shell | `Enter` / double-click | Load selected cart |
| Shell | drop a `.zip`/dir | Insert at any time |
| Shell | double-click **OPEN FILE** | `SDL_ShowOpenFileDialog` |
| Cart | `CTRL+ESC` | Eject back to the shell |
| Anywhere | `CMD+Q` | Quit |

---

## Architecture & API

### The C ABI (host ⇄ shim)

The Embedded-Swift host declares these via `@_silgen_name` in `host-main.swift`; each per-OS shim implements them.

```c
void wasm5_play_cart(void *nswindow, const char *cartPath); // resolve+serve cart, attach WKWebView
void wasm5_eject(void);                                     // remove webview, kill http server
void wasm5_activate(void *nswindow);                        // foreground + key the window
void wasm5_pump_runloop(double seconds);                    // drain NSApp event queue (keys → webview)
int  wasm5_eject_requested(void);                           // polled: CTRL+ESC fired?
int  wasm5_quit_requested(void);                            // polled: CMD+Q fired?
void wasm5_install_keymonitor(void);                        // install the app-wide NSEvent monitor
```

The host exports one callback the monitor calls back into:

```swift
@_cdecl("wasm5_push_key")
func wasm5_push_key(_ sfcode: Int32)   // feeds Kit.shared.pushEvent (shell nav, bypassing SDL)
```

### Threads & loop

`@main enum Main` boots the kit, loads Apple Color Emoji + the pref store, presents `ShellScene` in an `SKView`, activates/keys the SDL window, installs the key monitor, then runs:

- **Game thread** — ticks + presents the shell (`shellTick` + `kitHostPresent`) only when **no cart is up**.
- **Main thread** — the OS event pump, cart insert/eject, and webview management.

The critical rule: **while a cart is up, the main loop must NOT pump SDL events.** SDL's pump dequeues the key `NSEvent`s and re-focuses its own content view, stealing the keyboard from the webview. Instead the host calls `wasm5_pump_runloop`, which uses `NSApp nextEventMatchingMask`/`sendEvent` (not bare `NSRunLoop runMode`) to drain the OS event queue so events reach the webview first responder — and the app doesn't beachball.

### Key types

- `final class ShellScene: SKScene` — `didMove` / `keyDown` / `mouseDown` / `update`. Scans the carts dir, draws a pick-and-play menu, auto-rescans every ~180 frames.
- `enum ShellFont` — 10×14 line-segment glyphs (`A–Z 0–9 - .`) with `draw` / `displayName` / `strokes`.

### Kit surface consumed from SuperBox64Kit

`kitHostInit`, `kitHostPump`, `kitHostPresent`, `kitEscapeReserved`, `kitEscapePressed`, `kitDroppedFile`, and `Kit.shared.{ window, pushEvent, setEmojiFont, setEmojiMode, emojiMode, storePath, loadStore, saveStore, storeGet, storeSet }`.

---

## Keyboard forwarding (the heart of Wasm5)

`webview-shim.m` installs one `NSEvent` local monitor and routes by mode:

```
key event
   │
   ├─ CMD+Q ────────────────────────► gQuitRequested = 1  (consume)
   │
   ├─ webview up?
   │     ├─ CTRL+ESC ───────────────► gEjectRequested = 1  (consume)
   │     └─ else ───────────────────► forwardKeyToWebview()  (consume)
   │            evaluateJavaScript:
   │              new KeyboardEvent('keydown'|'keyup', { code, key, bubbles, cancelable })
   │              dispatched on window AND document  (runtime.js reads e.code)
   │
   └─ shell (no cart)
         └─ macToSf(keyCode) ────────► wasm5_push_key(sfcode)  (consume nav keys)
```

`macToDomCode` maps macOS virtual key codes to DOM `KeyboardEvent.code` strings: arrows → `ArrowLeft/Right/Up/Down`, `Space`/`Enter`/`NumpadEnter`/`Escape`/`Tab`/`Backspace`/`ShiftLeft`, letters → `KeyA…KeyZ`, digits → `Digit0…Digit9`. The injection is **focus-independent** — `runtime.js` listens on global `keydown`/`keyup`, so no first-responder dance is needed for the cart to feel the keys.

---

## Cross-platform notes

The host talks to the webview only through the 7-function C ABI, so porting is "write another shim":

| OS | Shim | Webview | Status |
|---|---|---|---|
| macOS | `webview-shim.m` | `WKWebView` added to the SDL window's `contentView`; `/usr/bin/unzip`; ATS exempted for localhost via `Info.plist` | working |
| Linux | `webview-shim-linux.c` | borderless GTK3 window holding a `WebKitWebView`, `XReparentWindow`'d into the SDL X11 window | **untested**, X11 only |
| Windows | `webview-shim-win.cpp` | WebView2 control as a child of the SDL `HWND`; cart extracted via PowerShell `Expand-Archive` | **untested** |

`Info.plist` declares `NSAppTransportSecurity → NSAllowsLocalNetworking = true` so the `WKWebView` can load the cart over `http://127.0.0.1` despite App Transport Security.

---

## Gotchas

- **SDL keyboard is broken with WebKit linked.** Do not assume SDL key events work; the whole monitor-and-forward design exists for this. Mouse works; keys don't.
- **Don't pump SDL while a cart is up** — it steals the keyboard from the webview. Use `wasm5_pump_runloop`.
- **`wasm5_activate` is required at launch** — linking WebKit/Cocoa can leave `NSApplication` un-activated (window visible but not key), which swallows every keystroke in the shell.
- **The shell still carries WasmCart naming.** The carts env var read at runtime is **`WASMCART_CARTS`** (not a Wasm5-specific name), and the pref-store key is literally `WasmCart.emojiMode`. The cartridge slot label is `WASMFIVE`.
- **EMOJI mode is a no-op for webview carts** — `emojiRect` is `.zero`; the browser renders emoji with the system font, so the kit's apple/png/noto mode has no effect.
- **Build ordering matters** — build WasmCart first, or `build.sh` aborts with `ERROR: build WasmCart first (need .../vendor/libSDL3.a)`.
- **DEBUG logging is left in by design** — `webview-shim.m` (`WASM5 MONITOR`/`FORWARD`) and `host-main.swift` (`WASM5 GAME-THREAD`/`SDL-KEYDOWN`/…) are noisy on purpose.
- **`main.swift.standalone-bak`** is a superseded earlier design: a plain CLI that took a cart arg (or `CARTRIDGE` env), served it on port **52850**, and showed it in a standalone `WKWebView` window. The current architecture serves on **52900**. Gitignored (`*.standalone-bak`).
- **Embedded Swift constraints** propagate from the kit: the build sed-strips `@MainActor`/`@preconcurrency` before compiling — keep that in mind when editing `host-main.swift` or `ShellScene.swift`.

---

## Repository layout

```
Wasm5/
├── host-main.swift           Embedded-Swift host: @main, C-ABI bridge, threads, cart slot
├── Sources/
│   └── ShellScene.swift      the console shell SKScene + ShellFont segment glyphs
├── webview-shim.m            macOS Cocoa/WebKit shim (the C ABI; real SDK, not Embedded)
├── webview-shim-linux.c      Linux WebKitGTK shim (untested)
├── webview-shim-win.cpp      Windows WebView2 shim (untested)
├── build.sh                  build driver (needs ../SuperBox64Kit and ../WasmCart)
├── Info.plist                CFBundleName Wasm5, com.superbox64.wasm5, ATS localhost
├── main.swift.standalone-bak superseded standalone CLI (gitignored)
└── carts/
    └── ufoemoji.zip          bundled sample cart (UFO Emoji web build); extracted copies gitignored
```

---

## Related repos

Part of the SuperBox64 / UFO Emoji constellation — one game source, seven build × runtime permutations:

- **[SuperBox64Kit](../SuperBox64Kit)** — *the kit.* A Swift reimplementation of Apple's SpriteKit that compiles one game-source tree three ways (browser wasm, wasm cartridge, native binary), bundling Box2D v3, an SDL3 backend, and a reSVG/nanosvg vector rasterizer. **Owns** SpriteKit emulation, the KitABI, Box2D-backed physics, the SDL3 backend, reSVG, and the drop-in story. Wasm5's shell *is* a kit `SKScene`, and `build.sh` calls the kit's `native/build-native-game.sh`.
- **[WasmKit](../WasmKit)** — *the web runtime.* The hand-rolled, no-Emscripten JavaScript host (`runtime.js`) that renders WASI/Embedded-Swift wasm games on Canvas2D and fulfils the KitABI env imports in the browser. **This is the exact runtime Wasm5's WKWebView carts run** — Wasm5 hosts it locally instead of on a web page.
- **[WasmCart](../WasmCart)** — *the native console.* Wasm5's sister/twin: same SDL3 shell, but it plays `.wasm`/`.aot` carts through **WAMR** (interpreter + wamrc AOT) — no browser, no JavaScript. Wasm5 **hard-depends** on its vendored `vendor/libSDL3.a`.
- **[UFO-Emoji-Arcade](../UFO-Emoji-Arcade)** — *the flagship game / demo.* Heisenburg' App Store arcade game UFO Emoji: one 100% Swift SpriteKit codebase shipped to iOS natively, to the browser via WebAssembly, and to native consoles — all from the same unchanged sources. Its web build is Wasm5's bundled sample cart.

---

## Credits

- **Author:** Heisenburg
- **Console & game:** part of the SuperBox64 / UFO Emoji project
- Built on [SuperBox64Kit](../SuperBox64Kit) (SpriteKit-for-wasm reimplementation, SDL3 backend, Box2D v3, reSVG), the [WasmKit](../WasmKit) `runtime.js` Canvas2D host, and [WasmCart](../WasmCart)'s vendored static SDL3
- Repo: `https://github.com/SuperBox64/Wasm5`

## License

No `LICENSE` file is currently present in this repository (or in the sibling consoles). All rights reserved by the author pending an explicit license. Add a `LICENSE` file to set terms.
