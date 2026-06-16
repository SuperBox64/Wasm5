// webview-shim-win.cpp — Windows (WebView2) implementation of the Wasm5 webview C ABI.
// Same 4 functions the Embedded-Swift host calls on every platform; here a WebView2
// control is embedded as a child of the SDL window's HWND, serving the cart's web build
// over a localhost http server.
//
// Build (MSVC): cl /std:c++17 /EHsc /c webview-shim-win.cpp
//   needs the WebView2 SDK (Microsoft.Web.WebView2 NuGet) + WIL on the include path,
//   and at link time WebView2Loader.dll + shlwapi.lib ole32.lib.
//
// NOTE: untested on this macOS host — provided as the cross-platform shim per the
// Wasm5 design (host unchanged; only the shim differs per OS).
#include <windows.h>
#include <shlwapi.h>
#include <wrl.h>
#include <wil/com.h>
#include <WebView2.h>
#include <string>
#include <cstdio>

using namespace Microsoft::WRL;

static wil::com_ptr<ICoreWebView2Controller> gController;
static wil::com_ptr<ICoreWebView2>           gWebView;
static PROCESS_INFORMATION                    gServer = {0};
static HWND                                   gParent = nullptr;
static const int                              kPort   = 52900;

// ---- helpers ---------------------------------------------------------------

static std::wstring widen(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    std::wstring w(n ? n - 1 : 0, L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

static bool hasIndex(const std::wstring &dir) {
    return PathFileExistsW((dir + L"\\index.html").c_str()) == TRUE;
}

// Resolve a cart path (directory, or .zip) to a folder containing index.html.
static std::wstring resolveWebDir(const std::wstring &path) {
    DWORD attr = GetFileAttributesW(path.c_str());
    if (attr != INVALID_FILE_ATTRIBUTES && (attr & FILE_ATTRIBUTE_DIRECTORY)) {
        if (hasIndex(path)) return path;
        // one level down (carts often wrap everything in a single folder)
        WIN32_FIND_DATAW fd; HANDLE h = FindFirstFileW((path + L"\\*").c_str(), &fd);
        if (h != INVALID_HANDLE_VALUE) {
            do {
                if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && fd.cFileName[0] != L'.') {
                    std::wstring sub = path + L"\\" + fd.cFileName;
                    if (hasIndex(sub)) { FindClose(h); return sub; }
                }
            } while (FindNextFileW(h, &fd));
            FindClose(h);
        }
        return L"";
    }
    if (path.size() > 4 && _wcsicmp(path.c_str() + path.size() - 4, L".zip") == 0) {
        wchar_t tmp[MAX_PATH]; GetTempPathW(MAX_PATH, tmp);
        std::wstring out = std::wstring(tmp) + L"wasm5-cart";
        // extract via PowerShell Expand-Archive (present on Win10+)
        std::wstring cmd = L"powershell -NoProfile -Command \"Expand-Archive -Force -LiteralPath '" +
                           path + L"' -DestinationPath '" + out + L"'\"";
        STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {0};
        si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
        if (CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                           nullptr, nullptr, &si, &pi)) {
            WaitForSingleObject(pi.hProcess, INFINITE);
            CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
        }
        return hasIndex(out) ? out : (hasIndex(out + L"\\") ? out : resolveWebDir(out));
    }
    return L"";
}

static void resizeToParent() {
    if (!gController || !gParent) return;
    RECT rc; GetClientRect(gParent, &rc);
    gController->put_Bounds(rc);
}

// ---- C ABI (matches webview-shim.m) ---------------------------------------

extern "C" void wasm5_play_cart(void *hwnd, const char *cartPath) {
    if (gWebView || !hwnd || !cartPath) return;
    std::wstring dir = resolveWebDir(widen(cartPath));
    if (dir.empty()) { fprintf(stderr, "Wasm5: no index.html for %s\n", cartPath); return; }
    gParent = (HWND)hwnd;

    // serve the cart over localhost (modules/wasm need HTTP, not file://)
    std::wstring cmd = L"python -m http.server " + std::to_wstring(kPort) +
                       L" --bind 127.0.0.1 --directory \"" + dir + L"\"";
    STARTUPINFOW si = { sizeof(si) }; si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    if (!CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                        nullptr, nullptr, &si, &gServer)) {
        fprintf(stderr, "Wasm5: http server failed (need python on PATH)\n"); return;
    }

    // create the WebView2 environment + controller as a child of the SDL HWND (async)
    CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [](HRESULT, ICoreWebView2Environment *env) -> HRESULT {
                env->CreateCoreWebView2Controller(gParent,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [](HRESULT, ICoreWebView2Controller *ctrl) -> HRESULT {
                            if (!ctrl) return S_OK;
                            gController = ctrl;
                            gController->get_CoreWebView2(&gWebView);
                            resizeToParent();
                            std::wstring url = L"http://127.0.0.1:" + std::to_wstring(kPort) + L"/index.html";
                            gWebView->Navigate(url.c_str());
                            return S_OK;
                        }).Get());
                return S_OK;
            }).Get());
}

extern "C" void wasm5_eject(void) {
    if (gController) { gController->Close(); gController = nullptr; gWebView = nullptr; }
    if (gServer.hProcess) {
        TerminateProcess(gServer.hProcess, 0);
        CloseHandle(gServer.hProcess); CloseHandle(gServer.hThread);
        gServer = {0};
    }
    gParent = nullptr;
}

extern "C" void wasm5_activate(void *hwnd) {
    if (hwnd) { SetForegroundWindow((HWND)hwnd); SetFocus((HWND)hwnd); }
}

// Pump the Win32 message loop (and keep the WebView2 sized to the SDL window) so the
// embedded browser runs while a cart is up. `seconds` bounds the time spent here.
extern "C" void wasm5_pump_runloop(double seconds) {
    resizeToParent();
    DWORD endTick = GetTickCount() + (DWORD)(seconds * 1000.0);
    MSG msg;
    do {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg); DispatchMessageW(&msg);
        }
    } while (GetTickCount() < endTick);
}
