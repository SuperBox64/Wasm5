// Wasm5 webview shim. The SDL3 shell + kit compile as Embedded Swift (no Foundation/
// Cocoa/WebKit), so all the AppKit/WebKit/HTTP-server work lives here in Objective-C and
// is driven from the Embedded host over a tiny C ABI: play a cart's web build in a
// WKWebView overlaid on the SDL window, eject it, and pump the run loop while it's up.
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <stdio.h>

static WKWebView *gWebView = nil;
static NSTask    *gServer  = nil;
static const int  kPort    = 52900;

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

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.html", kPort]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gWebView == wv) [wv loadRequest:[NSURLRequest requestWithURL:url]];
    });
}

void wasm5_eject(void) {
    if (gWebView) { [gWebView removeFromSuperview]; gWebView = nil; }
    if (gServer)  { [gServer terminate]; gServer = nil; }
}

// Service the main run loop so WebKit's networking/JS/rendering run while a cart is up.
void wasm5_pump_runloop(double seconds) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
