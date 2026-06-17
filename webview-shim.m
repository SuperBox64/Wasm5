// Wasm5 webview shim. The SDL3 shell + kit compile as Embedded Swift (no Foundation/
// Cocoa/WebKit), so all the AppKit/WebKit/HTTP-server work lives here in Objective-C and
// is driven from the Embedded host over a tiny C ABI: play a cart's web build in a
// WKWebView overlaid on the SDL window, eject it, and pump the run loop while it's up.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <stdio.h>

static WKWebView *gWebView = nil;
static NSTask    *gServer  = nil;
static NSWindow  *gWindow  = nil;
static id         gKeyMonitor = nil;
static volatile int gEjectRequested = 0;
static volatile int gQuitRequested  = 0;
static const int  kPort    = 52900;

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

// Inject the keystroke straight into the webview's JS as a synthetic KeyboardEvent —
// no first-responder/focus needed (runtime.js listens on window keydown/keyup, e.code).
static void forwardKeyToWebview(NSEvent *e, BOOL down) {
    if (!gWebView) return;
    NSString *code = macToDomCode(e);
    if (!code) { fprintf(stderr, "WASM5 FORWARD: no DOM code for keyCode=%d\n", e.keyCode); return; }
    NSString *js = [NSString stringWithFormat:
        @"(function(){var ev=new KeyboardEvent('%@',{code:'%@',key:'%@',bubbles:true,cancelable:true});"
         "var n1=window.dispatchEvent(ev);var ev2=new KeyboardEvent('%@',{code:'%@',key:'%@',bubbles:true,cancelable:true});"
         "var n2=document.dispatchEvent(ev2);"
         "return 'code='+ev.code+' winPrevented='+ev.defaultPrevented+' docPrevented='+ev2.defaultPrevented;})();",
        down ? @"keydown" : @"keyup", code, code, down ? @"keydown" : @"keyup", code, code];
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

// Show a cart's web build in a WKWebView over the SDL window. MAIN THREAD ONLY.
void wasm5_play_cart(void *nswindow, const char *cartPath) {
    if (gWebView || nswindow == NULL || cartPath == NULL) return;
    NSString *dir = resolveWebDir([NSString stringWithUTF8String:cartPath]);
    if (!dir) { fprintf(stderr, "Wasm5: no index.html for %s\n", cartPath); return; }

    NSTask *srv = [[NSTask alloc] init];
    srv.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
    srv.arguments = @[@"python3", @"-m", @"http.server", [@(kPort) stringValue],
                      @"--bind", @"127.0.0.1", @"--directory", dir];
    srv.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    srv.standardError  = [NSFileHandle fileHandleWithNullDevice];
    if (![srv launchAndReturnError:nil]) { fprintf(stderr, "Wasm5: http server failed (need python3)\n"); return; }
    gServer = srv;

    NSWindow *win = (__bridge NSWindow *)nswindow;
    NSView *content = win.contentView;
    WKWebView *wv = [[WKWebView alloc] initWithFrame:content.bounds
                                       configuration:[[WKWebViewConfiguration alloc] init]];
    wv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:wv];
    gWebView = wv;
    gWindow  = win;
    // Hand keyboard focus to the webview so keystrokes reach the cart (Canvas2D game),
    // not SDL's content view — otherwise the SDL host eats them (e.g. F = fullscreen).
    [win makeFirstResponder:wv];
    gEjectRequested = 0;   // the app-wide key monitor (CTRL+ESC) handles eject

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.html", kPort]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gWebView == wv) [wv loadRequest:[NSURLRequest requestWithURL:url]];
    });
}

void wasm5_eject(void) {
    if (gWebView) { [gWebView removeFromSuperview]; gWebView = nil; }
    if (gServer)  { [gServer terminate]; gServer = nil; }
    // give keyboard focus back to SDL's view so the shell responds to keys again
    if (gWindow) { [gWindow makeFirstResponder:gWindow.contentView]; gWindow = nil; }
}

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
