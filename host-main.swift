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
@_silgen_name("wasm5_eject_requested")
func wasm5_eject_requested() -> Int32
@_silgen_name("wasm5_quit_requested")
func wasm5_quit_requested() -> Int32
@_silgen_name("wasm5_install_keymonitor")
func wasm5_install_keymonitor()
@_silgen_name("wasm5_start_server")
func wasm5_start_server() -> Int32
@_silgen_name("wasm5_shutdown_server")
func wasm5_shutdown_server()

// Called by the shim's key monitor: feed an SFML key code straight into the kit event
// queue (SDL's keyboard is unreliable with WebKit linked, so we bypass it for the shell).
@_cdecl("wasm5_push_key")
func wasm5_push_key(_ sfcode: Int32) {
    Kit.shared.pushEvent((5, sfcode, 0, 0, 0))
    Kit.shared.pushEvent((6, sfcode, 0, 0, 0))   // immediate key-up; the shell only acts on key-down
}

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
        wasm5_install_keymonitor()   // route keyboard via a macOS monitor (SDL's keys are broken with WebKit linked)
        _ = wasm5_start_server()     // one persistent http.server; cart loads just repoint its serving symlink

        // game thread: tick + present the shell whenever no webview cart is up
        let gameThread = SDL_CreateThreadRuntime({ _ in
            var last = SDL_GetTicksNS()
            var gtick = 0
            while SDL_GetAtomicInt(&runFlag) == 1 {
                let now = SDL_GetTicksNS()
                var dt = Float(now - last) / 1_000_000; last = now
                if dt > 50 { dt = 50 }
                if SDL_GetAtomicInt(&cartLoaded) == 0 {
                    shellTick(Double(dt))
                    kitHostPresent()
                }
                gtick += 1
                if gtick % 60 == 0 { print("WASM5 GAME-THREAD looping frame=\(gtick) cartLoaded=\(SDL_GetAtomicInt(&cartLoaded))") }  // DEBUG
                SDL_DelayNS(16_666_666)
            }
            return 0
        }, "shell", nil, nil, nil)

        // main thread: OS event pump + console controls + webview management
        var shownFPS: Int32 = -1
        var dbgTick = 0
        var dbgKeys = [Bool](repeating: false, count: 512)   // DEBUG: detect SDL key-down transitions
        while SDL_GetAtomicInt(&runFlag) == 1 {
            let fps = SDL_GetAtomicInt(&currentFPS)
            if fps != shownFPS {
                shownFPS = fps
                _ = "Wasm5".withCString { SDL_SetWindowTitle(Kit.shared.window, $0) }
            }
            if wasm5_quit_requested() != 0 { SDL_SetAtomicInt(&runFlag, 0); break }   // CMD+Q

            if SDL_GetAtomicInt(&cartLoaded) == 1 {
                // A cart's webview owns the window. Do NOT pump SDL here — SDL's event
                // pump dequeues the key NSEvents and re-focuses its own content view,
                // stealing the keyboard from the webview. Instead let the Cocoa run loop
                // dispatch events straight to the webview (first responder). CTRL+ESC is
                // caught by the shim's local monitor.
                if wasm5_eject_requested() != 0 { hideWebCart() }
                else { wasm5_pump_runloop(0.012) }
                continue
            }

            // shell: SDL owns the window — pump events + handle console controls
            if !kitHostPump() { SDL_SetAtomicInt(&runFlag, 0); break }
            // DEBUG: print SDL key-down transitions (does SDL receive the arrows at all?)
            var nk: Int32 = 0
            if let st = SDL_GetKeyboardState(&nk) {
                let n = min(Int(nk), 512)
                for i in 0..<n {
                    if st[i] && !dbgKeys[i] { print("WASM5 SDL-KEYDOWN scancode=\(i)") }
                    dbgKeys[i] = st[i]
                }
            }
            dbgTick += 1   // DEBUG: ~once/sec, report whether the shell window has keyboard focus
            if dbgTick >= 250 {
                dbgTick = 0
                let focused = (SDL_GetWindowFlags(Kit.shared.window) & 0x200) != 0   // SDL_WINDOW_INPUT_FOCUS
                var nk: Int32 = 0
                var anyKey = false
                if let st = SDL_GetKeyboardState(&nk) { for i in 0..<Int(nk) where st[i] { anyKey = true; break } }
                print("WASM5 DBG  inputFocus=\(focused)  anyKeyDownNow=\(anyKey)")
            }
            if let p = takePendingCart() { showWebCart(p) }
            kitEscapePressed = false
            if SDL_GetAtomicInt(&ejectFlag) == 1 { SDL_SetAtomicInt(&ejectFlag, 0) }
            if SDL_GetAtomicInt(&wantDialog) == 1 { SDL_SetAtomicInt(&wantDialog, 0); openCartDialog() }
            if let dropped = kitDroppedFile { kitDroppedFile = nil; insertCart(dropped) }
            SDL_DelayNS(4_000_000)
        }

        hideWebCart()
        wasm5_shutdown_server()   // stop the persistent http.server on exit (don't orphan it)
        SDL_WaitThread(gameThread, nil)
        SDL_Quit()
    }
}
