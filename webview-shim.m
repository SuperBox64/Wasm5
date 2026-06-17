// Wasm5 webview shim. The SDL3 shell + kit compile as Embedded Swift (no Foundation/
// Cocoa/WebKit), so all the AppKit/WebKit/HTTP-server work lives here in Objective-C and
// is driven from the Embedded host over a tiny C ABI: play a cart's web build in a
// WKWebView overlaid on the SDL window, eject it, and pump the run loop while it's up.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <stdio.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>

static WKWebView *gWebView = nil;
static NSTask    *gServer  = nil;   // ONE persistent http.server for the whole app lifetime
static NSWindow  *gWindow  = nil;
static id         gKeyMonitor = nil;
static volatile int gEjectRequested = 0;
static volatile int gQuitRequested  = 0;
static const int  kPort    = 52900;
static NSString  *gServeLink = nil;   // stable symlink the server serves; repoint to swap carts
static NSString  *gEmptyDir = nil;   // empty placeholder dir (what the link points at when no cart is loaded)

extern void wasm5_push_key(int sfcode);   // host: push an SFML key code into the kit event queue

// Polled by the host each frame. CTRL+ESC ejects; CMD+Q quits. (The monitor sees these
// even when the webview owns the keyboard.)
int wasm5_eject_requested(void) { int r = gEjectRequested; gEjectRequested = 0; return r; }
int wasm5_quit_requested(void)  { return gQuitRequested; }

// SDL3's macOS keyboard path is unreliable when WebKit is linked into the process (mouse
// works, keys never reach SDL's content view). So we install ONE app-wide key monitor:
//  - shell (no cart): translate nav keys to SFML codes and feed the kit directly;
//  - cart (webview):  let keys flow to the webview, but grab CTRL+ESC / CMD+Q.
// macOS virtual keyCode -> SFML code (for the SHELL, fed to the kit).
static int macToSf(unsigned short kc) {
    switch (kc) {
        case 126: return 73; case 125: return 74; case 123: return 71; case 124: return 72;  // arrows
        case 36: case 76: return 58;  // return/enter
        case 49: return 57;           // space
        case 14: return 4;            // E
        default: return -1;
    }
}

// macOS NSEvent -> DOM KeyboardEvent.code string (what runtime.js reads). nil = skip.
static NSString *macToDomCode(NSEvent *e) {
    switch (e.keyCode) {
        case 123: return @"ArrowLeft";  case 124: return @"ArrowRight";
        case 125: return @"ArrowDown";  case 126: return @"ArrowUp";
        case 49:  return @"Space";      case 36:  return @"Enter";   case 76: return @"NumpadEnter";
        case 53:  return @"Escape";     case 48:  return @"Tab";     case 51: return @"Backspace";
        case 56: case 60: return @"ShiftLeft";
        default: break;
    }
    NSString *ch = [e.charactersIgnoringModifiers lowercaseString];
    if (ch.length == 1) {
        unichar c = [ch characterAtIndex:0];
        if (c >= 'a' && c <= 'z') return [NSString stringWithFormat:@"Key%C", (unichar)(c - 32)];
        if (c >= '0' && c <= '9') return [NSString stringWithFormat:@"Digit%C", c];
    }
    return nil;
}

// Inject the keystroke into the webview's JS as a synthetic KeyboardEvent, dispatched on
// the FOCUSED element so it bubbles up like a real keypress: target -> documentElement ->
// document -> window. That reaches a cart's listener no matter which level it's on
// (ufoemoji listens on window; webrcade/Stella listens on document.documentElement — and DOM
// events only bubble UP, so a window/document dispatch never reached documentElement, which
// is why atari2600 got no keys). keyCode is set too (some webrcade paths read it).
static void forwardKeyToWebview(NSEvent *e, BOOL down) {
    if (!gWebView) return;
    NSString *code = macToDomCode(e);
    if (!code) { fprintf(stderr, "WASM5 FORWARD: no DOM code for keyCode=%d\n", e.keyCode); return; }
    NSString *js = [NSString stringWithFormat:
        @"(function(){"
         "var type='%@',code='%@';"
         "var kc={ArrowUp:38,ArrowDown:40,ArrowLeft:37,ArrowRight:39,Space:32,Enter:13,NumpadEnter:13,Escape:27,Tab:9,Backspace:8,"
         "ShiftLeft:16,ShiftRight:16,ControlLeft:17,ControlRight:17,AltLeft:18,AltRight:18,MetaLeft:91,MetaRight:91};"
         "if(!(code in kc)){if(/^Key[A-Z]$/.test(code))kc[code]=code.charCodeAt(3);else if(/^Digit[0-9]$/.test(code))kc[code]=code.charCodeAt(5);}"
         "var ev=new KeyboardEvent(type,{code:code,key:code,bubbles:true,cancelable:true});"
         "var k=kc[code]||0;if(k){Object.defineProperty(ev,'keyCode',{value:k});Object.defineProperty(ev,'which',{value:k});}"
         "var t=document.activeElement||document.body;t.dispatchEvent(ev);"   // bubbles up through documentElement -> document -> window
         "return 'tgt='+(t&&t.tagName)+' code='+ev.code+' kc='+ev.keyCode+' prev='+ev.defaultPrevented;"
         "})();",
        down ? @"keydown" : @"keyup", code];
    [gWebView evaluateJavaScript:js completionHandler:^(id r, NSError *err) {   // DEBUG
        if (err) fprintf(stderr, "WASM5 FORWARD %s js error: %s\n", code.UTF8String, err.localizedDescription.UTF8String);
        else     fprintf(stderr, "WASM5 FORWARD %s -> %s\n", down ? "down" : "up", r ? [[r description] UTF8String] : "nil");
    }];
}

void wasm5_install_keymonitor(void) {
    if (gKeyMonitor) return;
    gKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskKeyDown | NSEventMaskKeyUp)
                                                        handler:^NSEvent *(NSEvent *e) {
        BOOL down = (e.type == NSEventTypeKeyDown);
        fprintf(stderr, "WASM5 MONITOR fire keyCode=%d down=%d webviewUp=%d\n", e.keyCode, down, gWebView != nil);   // DEBUG
        BOOL cmd  = (e.modifierFlags & NSEventModifierFlagCommand) != 0;
        BOOL ctrl = (e.modifierFlags & NSEventModifierFlagControl) != 0;
        if (down && cmd && e.keyCode == 12 /* Q */) { gQuitRequested = 1; return nil; }
        if (gWebView) {
            if (down && ctrl && e.keyCode == 53 /* esc */) { gEjectRequested = 1; return nil; }
            forwardKeyToWebview(e, down);   // inject into the cart's JS (focus-independent)
            return nil;                     // we handled it
        }
        if (down) { int sf = macToSf(e.keyCode); if (sf >= 0) { wasm5_push_key(sf); return nil; } }  // shell nav
        return e;
    }];
}

// Resolve a cart path (a directory, or a .zip) to a folder containing index.html.
static NSString *resolveWebDir(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *(^findIndex)(NSString *) = ^NSString *(NSString *root) {
        if ([fm fileExistsAtPath:[root stringByAppendingPathComponent:@"index.html"]]) return root;
        for (NSString *k in [fm contentsOfDirectoryAtPath:root error:nil] ?: @[]) {
            NSString *sub = [root stringByAppendingPathComponent:k];
            if ([fm fileExistsAtPath:[sub stringByAppendingPathComponent:@"index.html"]]) return sub;
        }
        return nil;
    };
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) return nil;
    if (isDir) return findIndex(path);
    if ([path hasSuffix:@".zip"]) {
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"wasm5-cart-%lu", (unsigned long)path.hash]];
        [fm removeItemAtPath:tmp error:nil];
        [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
        NSTask *uz = [[NSTask alloc] init];
        uz.executableURL = [NSURL fileURLWithPath:@"/usr/bin/unzip"];
        uz.arguments = @[@"-oq", path, @"-d", tmp];
        uz.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        uz.standardError  = [NSFileHandle fileHandleWithNullDevice];
        [uz launchAndReturnError:nil];
        [uz waitUntilExit];
        return findIndex(tmp);
    }
    return nil;
}

// --- one persistent http.server; swap carts by repointing a symlink ------------
// A single python http.server runs on kPort for the whole app lifetime. Its --directory
// is a STABLE SYMLINK (gServeLink). To play a cart we repoint that symlink at the cart's
// extracted dir (ln -sfn); the running server re-resolves the symlink per request and
// serves the new cart instantly — no per-cart spawn/kill, so no port collisions, no
// orphaned servers piling up across carts, and no wrong-cart 404s from a stale listener.
// (If a prior run crashed mid-cart, its lone orphan is reclaimed once, at server start.)

// Is anything listening on 127.0.0.1:port? (cheap TCP connect; no subprocess.)
static BOOL portListening(int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return NO;
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    BOOL up = (connect(s, (struct sockaddr *)&a, sizeof a) == 0);
    close(s);
    return up;
}

// PID of the process listening on 127.0.0.1:port (0 if none). Used to confirm the
// listener is OUR server, not a stale one that survived reclaim.
static pid_t portListenerPid(int port) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
    t.arguments = @[@"-c", [NSString stringWithFormat:
        @"/usr/sbin/lsof -ti tcp:%d -sTCP:LISTEN 2>/dev/null", port]];
    NSPipe *out = [NSPipe pipe];
    t.standardOutput = out;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    [t launchAndReturnError:nil];
    [t waitUntilExit];
    NSString *s = [[NSString alloc] initWithData:[[out fileHandleForReading] readDataToEndOfFile]
                                          encoding:NSUTF8StringEncoding];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return s.length ? (pid_t)[s integerValue] : 0;
}

// Kill any stale listener on our port (SIGTERM, then SIGKILL if it won't go).
static void reclaimPort(int port) {
    for (int pass = 0; pass < 2; pass++) {
        if (!portListening(port)) return;
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        t.arguments = @[@"-c", [NSString stringWithFormat:
            pass == 0 ? @"/usr/sbin/lsof -ti tcp:%d -sTCP:LISTEN 2>/dev/null | xargs kill 2>/dev/null"
                      : @"/usr/sbin/lsof -ti tcp:%d -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null",
            port]];
        t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        t.standardError  = [NSFileHandle fileHandleWithNullDevice];
        [t launchAndReturnError:nil];
        [t waitUntilExit];
        [NSThread sleepForTimeInterval:0.05];   // let the killed socket release
    }
}

// Repoint the serving symlink at `dir` (atomic-ish: ln -sfn replaces the link in place).
// The running http.server re-resolves it on the next request, so the cart swaps instantly.
static void pointServerAt(NSString *dir) {
    if (!gServeLink || !dir) return;
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/bin/ln"];
    t.arguments = @[@"-sfn", dir, gServeLink];   // -s symlink, -f force, -n replace (don't descend into)
    t.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    t.standardError  = [NSFileHandle fileHandleWithNullDevice];
    [t launchAndReturnError:nil];
    [t waitUntilExit];
}

// Start the persistent server once (and restart it if it ever dies). Serves the empty
// placeholder until a cart is loaded. Returns YES once OUR process is listening on kPort.
static BOOL ensureServer(void) {
    if (gServer && portListening(kPort) && portListenerPid(kPort) == [gServer processIdentifier]) return YES;
    if (gServer) { [gServer terminate]; gServer = nil; }   // it died — clean up before restarting

    NSFileManager *fm = [NSFileManager defaultManager];
    if (!gServeLink) gServeLink = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wasm5-serving"];
    if (!gEmptyDir)  gEmptyDir  = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wasm5-empty"];
    [fm createDirectoryAtPath:gEmptyDir withIntermediateDirectories:YES attributes:nil error:nil];
    pointServerAt(gEmptyDir);   // serve nothing until a cart loads

    reclaimPort(kPort);   // one-time: kill any orphan left by a prior crashed run

    NSTask *srv = [[NSTask alloc] init];
    srv.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    srv.arguments = @[@"python3", @"-m", @"http.server", [@(kPort) stringValue],
                      @"--bind", @"127.0.0.1", @"--directory", gServeLink];
    srv.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    srv.standardError  = [NSFileHandle fileHandleWithNullDevice];
    if (![srv launchAndReturnError:nil]) { fprintf(stderr, "Wasm5: http server failed (need python3)\n"); return NO; }
    gServer = srv;

    // Wait until OUR server owns kPort. env execs python3 in place, so srv's PID is the
    // listener's. If it never binds, bail (no cart loaded) instead of serving a stale one.
    pid_t ourPid = [srv processIdentifier];
    for (int i = 0; i < 20; i++) {           // up to ~0.5s
        if (portListening(kPort)) {
            if (portListenerPid(kPort) == ourPid) return YES;
            break;   // someone else holds our port — give up rather than serve the wrong cart
        }
        [NSThread sleepForTimeInterval:0.025];
    }
    fprintf(stderr, "Wasm5: http server failed to bind port %d\n", kPort);
    if (gServer) { [gServer terminate]; gServer = nil; }
    return NO;
}

// Show a cart's web build in a WKWebView over the SDL window. MAIN THREAD ONLY.
void wasm5_play_cart(void *nswindow, const char *cartPath) {
    if (gWebView || nswindow == NULL || cartPath == NULL) return;
    NSString *dir = resolveWebDir([NSString stringWithUTF8String:cartPath]);
    if (!dir) { fprintf(stderr, "Wasm5: no index.html for %s\n", cartPath); return; }

    // The server is already running (started at launch). Point it at this cart's dir; the
    // running http.server re-resolves the symlink and serves the new cart instantly. No
    // per-cart spawn/kill -> no port collisions, no orphans, no wrong-cart 404s.
    if (!ensureServer()) return;   // safety net: restart it if it ever died, else bail
    pointServerAt(dir);

    NSWindow *win = (__bridge NSWindow *)nswindow;
    NSView *content = win.contentView;

    // Inject a keyboard navigator into the cart's ROM picker (the atari2600 cart's
    // play.html lists its ROMs as mouse-only .rom cards — no key handler — so arrow/
    // enter did nothing there and you couldn't pick a game with the keyboard). This
    // user script runs at document-end on every page: on the picker (#grid) it turns
    // the cards into a keyboard menu (arrows move, Enter/Space launches the highlighted
    // ROM); on an in-game page there's no #grid, so it no-ops and the real game keys
    // flow straight to Stella via the documentElement keydown listener our
    // forwardKeyToWebview synthetic events bubble up to. This is the "listen on window"
    // the host needs because the cart's own picker has no listener.
    NSString *pickerNavJS = @"(function(){"
        "var grid=document.getElementById('grid');if(!grid)return;"            // not the picker page
        "var sel=0;function C(){return grid.querySelectorAll('.rom');}"
        "function paint(){var c=C();for(var i=0;i<c.length;i++){c[i].style.outline=i===sel?'3px solid #e0392b':'none';c[i].style.background=i===sel?'#262626':'';}if(c[sel])c[sel].scrollIntoView({block:'nearest'});}"
        "new MutationObserver(paint).observe(grid,{childList:true});"          // cards load async via fetch('rom/')
        "setTimeout(paint,150);setTimeout(paint,1200);"
        "window.addEventListener('keydown',function(e){var c=C();if(!c.length)return;var k=e.code;"
        "if(k==='ArrowRight'||k==='ArrowDown'){sel=(sel+1+c.length)%c.length;paint();e.preventDefault();}"
        "else if(k==='ArrowLeft'||k==='ArrowUp'){sel=(sel-1+c.length)%c.length;paint();e.preventDefault();}"
        "else if(k==='Enter'||k==='Space'){if(c[sel])c[sel].dispatchEvent(new MouseEvent('click',{bubbles:true}));e.preventDefault();}});"
        "grid.addEventListener('mouseover',function(e){var c=C();for(var i=0;i<c.length;i++){if(c[i]===e.target||c[i].contains(e.target)){sel=i;paint();break;}}});"
        "})();";
    WKUserContentController *uc = [[WKUserContentController alloc] init];
    [uc addUserScript:[[WKUserScript alloc] initWithSource:pickerNavJS
                                         injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                         forMainFrameOnly:YES]];
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.userContentController = uc;
    WKWebView *wv = [[WKWebView alloc] initWithFrame:content.bounds configuration:cfg];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:wv];
    gWebView = wv;
    gWindow  = win;
    // Hand keyboard focus to the webview so keystrokes reach the cart (Canvas2D game),
    // not SDL's content view — otherwise the SDL host eats them (e.g. F = fullscreen).
    [win makeFirstResponder:wv];
    gEjectRequested = 0;   // the app-wide key monitor (CTRL+ESC) handles eject

    // Cache-bust with a per-load timestamp: every cart serves the same URL (/index.html),
    // so without this WKWebView reuses the previous cart's cached index.html when switching
    // carts (e.g. Atari -> UFO Emoji would show Atari again). A unique query forces a fetch.
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.html?t=%lld",
                                        kPort, (long long)([NSDate timeIntervalSinceReferenceDate] * 1000.0)]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gWebView == wv) [wv loadRequest:[NSURLRequest requestWithURL:url]];
    });
}

void wasm5_eject(void) {
    if (gWebView) { [gWebView removeFromSuperview]; gWebView = nil; }
    // The server is persistent (kept across carts); just stop serving this cart's data.
    pointServerAt(gEmptyDir);
    // give keyboard focus back to SDL's view so the shell responds to keys again
    if (gWindow) { [gWindow makeFirstResponder:gWindow.contentView]; gWindow = nil; }
}

// Start the one persistent http.server (called once at app launch). It runs for the
// whole app lifetime; cart loads just repoint the serving symlink. Returns 1 on success.
int wasm5_start_server(void) { return ensureServer() ? 1 : 0; }

// Tear down the server on app exit so we don't orphan it. (A crash orphan is reclaimed
// at the next launch by ensureServer's one-time reclaimPort.)
void wasm5_shutdown_server(void) { if (gServer) { [gServer terminate]; gServer = nil; } }

// Make the app a regular foreground app and the SDL window key, so it receives
// keyboard events. Linking WebKit/Cocoa can leave the NSApplication un-activated
// (window visible but not key), which swallows all keystrokes in the shell.
void wasm5_activate(void *nswindow) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];
    if (nswindow) {
        NSWindow *win = (__bridge NSWindow *)nswindow;
        [win makeKeyAndOrderFront:nil];
    }
}

// Pump the NSApplication event queue (NOT just the run loop) while a cart is up: this
// keeps the app responsive (no beachball) AND dispatches NSEvents — including keystrokes
// — to the key window's first responder, i.e. the webview. (NSRunLoop runMode alone
// services run-loop sources but never drains the OS event queue, so the app appears
// hung.) The webview is first responder and SDL isn't pumping, so keys reach the cart.
void wasm5_pump_runloop(double seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSEvent *e;
    while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
                                      inMode:NSDefaultRunLoopMode dequeue:YES]) != nil) {
        [NSApp sendEvent:e];
        if ([until timeIntervalSinceNow] <= 0) break;
    }
}
