#ifndef NOMINMAX
#define NOMINMAX
#endif
#include "WindowsEditor.hpp"
#include <windows.h>
#include <windowsx.h>
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <vector>

using namespace hasio;
namespace {
int forwarded = 0;
LRESULT CALLBACK hostProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    if (m == WM_KEYDOWN && (w == VK_BACK || w == VK_ESCAPE || w == VK_RETURN)) ++forwarded;
    return DefWindowProcW(h, m, w, l);
}
void pump() { MSG msg{}; while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); } }
void click(HWND h, int x, int y) { SendMessageW(h, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(x, y)); SendMessageW(h, WM_LBUTTONUP, 0, MAKELPARAM(x, y)); }
void capture(HWND window, const wchar_t* path) {
    HDC screen = GetDC(window), dc = CreateCompatibleDC(screen);
    BITMAPINFO info{}; info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER); info.bmiHeader.biWidth = editorWidth;
    info.bmiHeader.biHeight = -editorHeight; info.bmiHeader.biPlanes = 1; info.bmiHeader.biBitCount = 32; info.bmiHeader.biCompression = BI_RGB;
    void* pixels = nullptr; HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
    assert(bitmap && pixels); auto old = SelectObject(dc, bitmap);
    SendMessageW(window, WM_PRINT, reinterpret_cast<WPARAM>(dc), PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND);
    GdiFlush();
    BITMAPFILEHEADER file{}; file.bfType = 0x4d42; file.bfOffBits = sizeof(file) + sizeof(BITMAPINFOHEADER);
    file.bfSize = file.bfOffBits + editorWidth * editorHeight * 4;
    std::ofstream output(std::filesystem::path(path), std::ios::binary);
    output.write(reinterpret_cast<const char*>(&file), sizeof(file)); output.write(reinterpret_cast<const char*>(&info.bmiHeader), sizeof(BITMAPINFOHEADER));
    output.write(static_cast<const char*>(pixels), editorWidth * editorHeight * 4); assert(output.good());
    SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(window, screen);
}
}
int main() {
    SetProcessDPIAware(); std::filesystem::create_directories("build");
    WNDCLASSW wc{}; wc.lpfnWndProc = hostProc; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"EssentialSampler.TestHost";
    assert(RegisterClassW(&wc));
    HWND parent = CreateWindowW(wc.lpszClassName, L"Essential Sampler UI tests", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        0, 0, editorWidth + 40, editorHeight + 80, nullptr, nullptr, wc.hInstance, nullptr);
    assert(parent);
    auto model = std::make_shared<Model>(); model->samples.publish(makeDemo());
    WindowsEditor editor(model, true);
    std::array<int, ParamCount> begins{}, changes{}, ends{};
    editor.setCallbacks([&](uint32_t p) { ++begins[p]; }, [&](uint32_t p, double) { ++changes[p]; }, [&](uint32_t p) { ++ends[p]; }, [] {});
    assert(editor.attach(parent)); assert(editor.attach(parent));
    HWND window = static_cast<HWND>(editor.nativeHandle()); assert(window && GetParent(window) == parent);
    SetForegroundWindow(parent); SetFocus(parent); pump();
    model->params[Start].store(.2); model->params[End].store(.6);
    SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(380, 350));
    SendMessageW(window, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(468, 350));
    SendMessageW(window, WM_LBUTTONUP, 0, MAKELPARAM(468, 350));
    assert(std::abs(model->params[Start].load() - (.2 + 88.0 / 884)) < 1e-9);
    assert(std::abs(model->params[End].load() - model->params[Start].load() - .4) < 1e-9);
    assert(begins[Start] == 1 && ends[Start] == 1 && begins[End] == 1 && ends[End] == 1);
    assert(GetFocus() == parent);
    for (auto key : {VK_BACK, VK_ESCAPE, VK_RETURN}) SendMessageW(window, WM_KEYDOWN, key, 0);
    assert(forwarded == 3);
    // Capture cancellation must close the host automation gesture exactly once.
    SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(1100, 207));
    SendMessageW(window, WM_CANCELMODE, 0, 0); SendMessageW(window, WM_LBUTTONUP, 0, 0);
    assert(begins[Tune] == 1 && ends[Tune] == 1 && changes[Tune] > 0);
    HWND startField = GetDlgItem(window, 100); assert(startField);
    SetFocus(startField); SetWindowTextW(startField, L"0.100 s"); SendMessageW(startField, WM_KEYDOWN, VK_RETURN, 0);
    auto sample = model->samples.snapshot(); assert(sample);
    assert(std::abs(model->params[Start].load() * sample->frames() / sample->rate - .1) < 1e-9);
    assert(GetFocus() == parent);
    click(window, 786, 510); // Zoom in.
    click(window, 470, 150); // Pan from overview.
    SendMessageW(window, WM_TIMER, 1, 0); UpdateWindow(window); capture(window, L"build/windows-sampler.bmp");
    click(window, 150, 90); click(window, 580, 163); click(window, 1200, 163);
    assert(model->params[DistEnabled].load() == 1 && model->params[ChorusEnabled].load() == 1);
    click(window, 800, 323); assert(changes[ChorusDepth] > 0);
    UpdateWindow(window); capture(window, L"build/windows-fx.bmp");
    for (uint32_t i = 0; i < ParamCount; ++i) assert(begins[i] == ends[i]);
    editor.detach(); editor.detach(); assert(!editor.nativeHandle());
    // A reopened editor can be detached while its decoder is still running.
    assert(editor.attach(parent)); editor.loadPath(L"does-not-exist-\u97f3.wav"); editor.detach(); assert(!model->loading.load());
    WindowsEditor standalone(model, false); assert(standalone.attach(parent)); window = static_cast<HWND>(standalone.nativeHandle());
    SetForegroundWindow(parent); SetFocus(window); pump();
    Note note; while (model->notes.pop(note)) {}
    SendMessageW(window, WM_KEYDOWN, 'A', 0); assert(model->notes.pop(note) && note.on && note.pitch == 60);
    SendMessageW(window, WM_KILLFOCUS, reinterpret_cast<WPARAM>(parent), 0);
    bool released = false; while (model->notes.pop(note)) if (!note.on || note.stopPreview) released = true;
    assert(released);
    standalone.detach(); DestroyWindow(parent); UnregisterClassW(wc.lpszClassName, wc.hInstance);
    std::puts("Windows editor gesture, focus, lifecycle and rendering tests passed.");
}
