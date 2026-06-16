// webview-shim-linux.c — Linux (WebKitGTK) implementation of the Wasm5 webview C ABI.
// Same 4 functions the Embedded-Swift host calls on every platform; here a WebKitWebView
// (inside a borderless GTK window) is reparented into the SDL window's X11 window so it
// overlays the shell, serving the cart's web build over a localhost http server.
//
// Build: cc -c webview-shim-linux.c $(pkg-config --cflags gtk+-3.0 webkit2gtk-4.1)
//   link: $(pkg-config --libs gtk+-3.0 webkit2gtk-4.1 x11)
//
// NOTE: untested on this macOS host. X11 only (Wayland would use a subsurface instead).
// If reparenting proves flaky on a given WM, drop the XReparentWindow call and the GTK
// window becomes a normal top-level cart window — same playback, separate window.
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <gdk/gdkx.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>

static GtkWidget   *gWindow  = NULL;
static WebKitWebView *gWebView = NULL;
static pid_t        gServer  = 0;
static Window       gParent  = 0;
static const int    kPort    = 52900;

static int hasIndex(const char *dir) {
    char p[4096]; snprintf(p, sizeof(p), "%s/index.html", dir);
    struct stat st; return stat(p, &st) == 0;
}

// Resolve a cart path (dir, or .zip) to a folder containing index.html.
// Caller frees the returned string.
static char *resolveWebDir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) return NULL;
    if (S_ISDIR(st.st_mode)) {
        if (hasIndex(path)) return strdup(path);
        DIR *d = opendir(path); struct dirent *e;
        if (d) {
            while ((e = readdir(d))) {
                if (e->d_name[0] == '.') continue;
                char sub[4096]; snprintf(sub, sizeof(sub), "%s/%s", path, e->d_name);
                if (hasIndex(sub)) { closedir(d); return strdup(sub); }
            }
            closedir(d);
        }
        return NULL;
    }
    size_t n = strlen(path);
    if (n > 4 && strcasecmp(path + n - 4, ".zip") == 0) {
        char tmp[] = "/tmp/wasm5-cartXXXXXX";
        if (!mkdtemp(tmp)) return NULL;
        char cmd[8192];
        snprintf(cmd, sizeof(cmd), "unzip -oq '%s' -d '%s'", path, tmp);
        if (system(cmd) != 0) return NULL;
        if (hasIndex(tmp)) return strdup(tmp);
        return resolveWebDir(tmp);   // one folder deep
    }
    return NULL;
}

static void ensureGtk(void) {
    static int inited = 0;
    if (!inited) { gtk_init(NULL, NULL); inited = 1; }
}

void wasm5_play_cart(void *nativewin, const char *cartPath) {
    if (gWindow || !nativewin || !cartPath) return;
    ensureGtk();
    char *dir = resolveWebDir(cartPath);
    if (!dir) { fprintf(stderr, "Wasm5: no index.html for %s\n", cartPath); return; }
    gParent = (Window)(uintptr_t)nativewin;

    // serve the cart over localhost
    gServer = fork();
    if (gServer == 0) {
        char ports[16]; snprintf(ports, sizeof(ports), "%d", kPort);
        int fd = open("/dev/null", O_WRONLY); if (fd >= 0) { dup2(fd, 1); dup2(fd, 2); }
        execlp("python3", "python3", "-m", "http.server", ports,
               "--bind", "127.0.0.1", "--directory", dir, (char *)NULL);
        _exit(127);
    }
    free(dir);

    // borderless GTK window holding the webview; reparent it into the SDL X11 window
    gWindow = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_decorated(GTK_WINDOW(gWindow), FALSE);
    gWebView = WEBKIT_WEB_VIEW(webkit_web_view_new());
    gtk_container_add(GTK_CONTAINER(gWindow), GTK_WIDGET(gWebView));
    gtk_widget_realize(gWindow);

    GdkWindow *gdkw = gtk_widget_get_window(gWindow);
    Display *dpy = GDK_WINDOW_XDISPLAY(gdkw);
    Window child = GDK_WINDOW_XID(gdkw);
    XReparentWindow(dpy, child, gParent, 0, 0);

    XWindowAttributes pa;
    if (XGetWindowAttributes(dpy, gParent, &pa))
        gtk_window_resize(GTK_WINDOW(gWindow), pa.width, pa.height);

    char url[64]; snprintf(url, sizeof(url), "http://127.0.0.1:%d/index.html", kPort);
    webkit_web_view_load_uri(gWebView, url);
    gtk_widget_show_all(gWindow);
}

void wasm5_eject(void) {
    if (gWindow) { gtk_widget_destroy(gWindow); gWindow = NULL; gWebView = NULL; }
    if (gServer > 0) { kill(gServer, SIGTERM); waitpid(gServer, NULL, 0); gServer = 0; }
    gParent = 0;
}

void wasm5_activate(void *nativewin) {
    (void)nativewin;   // X11/WM handles focus; nothing reliable to force here
}

// Pump the GTK main loop so WebKit runs while a cart is up; `seconds` is advisory.
void wasm5_pump_runloop(double seconds) {
    (void)seconds;
    ensureGtk();
    int guard = 0;
    while (gtk_events_pending() && guard++ < 1000) gtk_main_iteration_do(FALSE);
}
