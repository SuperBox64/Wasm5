// Wasm5: the WasmCart console shell (a SuperBox64Kit SKScene rendered through SDL3),
// but carts play in a WKWebView instead of WAMR — the cart's WEB build (index.html +
// runtime.js + .wasm + assets), the real Canvas2D/browser stack. Same shell UI as
// WasmCart; only cart playback differs. The host compiles as Embedded Swift (like the
// kit), so all AppKit/WebKit/HTTP lives in webview-shim.m, called over this C ABI.
//
//   ./Wasm5                 empty slot: pick a cart from carts/ (a web-build dir or .zip)
//   CTRL+ESC ejects the webview back to the shell.
import SpriteKit
import CSDL3

@_silgen_name("wasm5_play_cart")
func wasm5_play_cart(_ nswindow: UnsafeMutableRawPointer?, _ path: UnsafePointer<CChar>?)
@_silgen_name("wasm5_eject")
func wasm5_eject()
@_silgen_name("wasm5_activate")
func wasm5_activate(_ nswindow: UnsafeMutableRawPointer?)
@_silgen_name("wasm5_pump_runloop")
func wasm5_pump_runloop(_ seconds: Double)

// MARK: - cart slot state (main thread inserts/ejects; game thread owns the shell tick)
nonisolated(unsafe) var slotMutex: OpaquePointer? = nil
nonisolated(unsafe) var pendingCartPath: String? = nil
nonisolated(unsafe) var runFlag = SDL_AtomicInt(value: 1)
nonisolated(unsafe) var cartLoaded = SDL_AtomicInt(value: 0)   // 1 = webview cart up, shell hidden
nonisolated(unsafe) var ejectFlag = SDL_AtomicInt(value: 0)
nonisolated(unsafe) var wantDialog = SDL_AtomicInt(value: 0)
nonisolated(unsafe) var currentFPS = SDL_AtomicInt(value: 0)
nonisolated(unsafe) var shellView: SKView? = nil

func insertCart(_ path: String) {
    SDL_LockMutex(slotMutex); pendingCartPath = path; SDL_UnlockMutex(slotMutex)
}
func takePendingCart() -> String? {
    SDL_LockMutex(slotMutex); let p = pendingCartPath; pendingCartPath = nil; SDL_UnlockMutex(slotMutex); return p
}
func shellTick(_ dtMs: Double) { shellView?.tick(dtMs) }

func openCartDialog() {
    SDL_ShowOpenFileDialog({ _, files, _ in
        if let files {
            var fp = files
            while let f = fp.pointee { insertCart(String(cString: f)); fp += 1 }
        }
    }, nil, Kit.shared.window, nil, 0, nil, false)
}

// The native window handle SDL exposes, per platform: a pointer (macOS NSWindow,
// Windows HWND) or a numeric X11 XID. The per-OS shim knows how to interpret it.
func nativeWindowPtr() -> UnsafeMutableRawPointer? {
    guard let win = Kit.shared.window else { return nil }
    let props = SDL_GetWindowProperties(win)
    for key in ["SDL.window.cocoa.window", "SDL.window.win32.hwnd"] {
        if let raw = key.withCString({ SDL_GetPointerProperty(props, $0, nil) }) { return raw }
    }
    let xid = "SDL.window.x11.window".withCString { SDL_GetNumberProperty(props, $0, 0) }
    if xid != 0 { return UnsafeMutableRawPointer(bitPattern: UInt(xid)) }
    return nil
}

func showWebCart(_ path: String) {
    guard SDL_GetAtomicInt(&cartLoaded) == 0, let raw = nativeWindowPtr() else { return }
    path.withCString { wasm5_play_cart(raw, $0) }
    SDL_SetAtomicInt(&cartLoaded, 1)
}
func hideWebCart() { wasm5_eject(); SDL_SetAtomicInt(&cartLoaded, 0) }

// MARK: - entry

@main
enum Main {
    static func main() {
        slotMutex = SDL_CreateMutex()
        kitEscapeReserved = true
        kitHostInit(appName: "Wasm5")

        // Emoji + store so the shell's EMOJI menu behaves like WasmCart's.
        func loadEmojiFont(_ paths: [String], _ set: (UnsafePointer<UInt8>, Int) -> Void) {
            for path in paths {
                var size = 0
                guard let data = path.withCString({ SDL_LoadFile($0, &size) }), size > 0 else { continue }
                set(UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: size), size); return
            }
        }
        loadEmojiFont(["/System/Library/Fonts/Apple Color Emoji.ttc"]) { Kit.shared.setEmojiFont($0, $1) }
        if let pref = ("SuperBox64".withCString { o in "Wasm5".withCString { SDL_GetPrefPath(o, $0) } }) {
            Kit.shared.storePath = String(cString: pref) + "store.tsv"
            SDL_free(UnsafeMutableRawPointer(mutating: pref))
            Kit.shared.loadStore()
        }
        if let saved = Kit.shared.storeGet("WasmCart.emojiMode"), let m = Int32(saved) { Kit.shared.setEmojiMode(m) }

        // the shell: the same SuperBox64Kit scene WasmCart uses
        let view = SKView()
        view.preferredFramesPerSecond = 60
        let shell = ShellScene(size: CGSize(width: 1920, height: 1080))
        shell.scaleMode = .aspectFill
        view.presentScene(shell)
        shellView = view

        // Foreground + key the SDL window so the shell actually receives keystrokes
        // (the WebKit/Cocoa link can otherwise leave the app un-activated).
        if let raw = nativeWindowPtr() { wasm5_activate(raw) }

        // game thread: tick + present the shell whenever no webview cart is up
        let gameThread = SDL_CreateThreadRuntime({ _ in
            var last = SDL_GetTicksNS()
            while SDL_GetAtomicInt(&runFlag) == 1 {
                let now = SDL_GetTicksNS()
                var dt = Float(now - last) / 1_000_000; last = now
                if dt > 50 { dt = 50 }
                if SDL_GetAtomicInt(&cartLoaded) == 0 {
                    shellTick(Double(dt))
                    kitHostPresent()
                }
                SDL_DelayNS(16_666_666)
            }
            return 0
        }, "shell", nil, nil, nil)

        // main thread: OS event pump + console controls + webview management
        var shownFPS: Int32 = -1
        while SDL_GetAtomicInt(&runFlag) == 1 {
            let fps = SDL_GetAtomicInt(&currentFPS)
            if fps != shownFPS {
                shownFPS = fps
                _ = "Wasm5".withCString { SDL_SetWindowTitle(Kit.shared.window, $0) }
            }
            if !kitHostPump() { SDL_SetAtomicInt(&runFlag, 0); break }
            if let p = takePendingCart() { showWebCart(p) }
            if kitEscapePressed {
                kitEscapePressed = false
                if SDL_GetAtomicInt(&cartLoaded) == 1 { hideWebCart() }
            }
            if SDL_GetAtomicInt(&ejectFlag) == 1 { SDL_SetAtomicInt(&ejectFlag, 0); hideWebCart() }
            if SDL_GetAtomicInt(&wantDialog) == 1 { SDL_SetAtomicInt(&wantDialog, 0); openCartDialog() }
            if let dropped = kitDroppedFile { kitDroppedFile = nil; insertCart(dropped) }
            // While a webview cart is up, service the main run loop so WebKit runs;
            // otherwise idle (the shell renders on the game thread).
            if SDL_GetAtomicInt(&cartLoaded) == 1 {
                wasm5_pump_runloop(0.008)
            } else {
                SDL_DelayNS(4_000_000)
            }
        }

        hideWebCart()
        SDL_WaitThread(gameThread, nil)
        SDL_Quit()
    }
}
