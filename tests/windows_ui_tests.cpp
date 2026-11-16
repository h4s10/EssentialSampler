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
void writeFixture(const std::filesystem::path& path) {
    std::ofstream file(path, std::ios::binary);
    auto little = [&](uint32_t value, unsigned bytes) { for (unsigned i = 0; i < bytes; ++i) file.put(static_cast<char>(value >> (i * 8))); };
    file.write("RIFF", 4); little(36 + 960, 4); file.write("WAVEfmt ", 8); little(16, 4); little(1, 2); little(1, 2);
    little(48000, 4); little(96000, 4); little(2, 2); little(16, 2); file.write("data", 4); little(960, 4);
    for (unsigned i = 0; i < 480; ++i) little(static_cast<uint16_t>(static_cast<int16_t>(std::sin(i * .12) * 16000)), 2);
    assert(file.good());
}
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
    int dirties = 0; const DWORD uiThread = GetCurrentThreadId();
    editor.setCallbacks([&](uint32_t p) { assert(GetCurrentThreadId() == uiThread); ++begins[p]; },
        [&](uint32_t p, double) { assert(GetCurrentThreadId() == uiThread); ++changes[p]; },
        [&](uint32_t p) { assert(GetCurrentThreadId() == uiThread); ++ends[p]; },
        [&] { assert(GetCurrentThreadId() == uiThread); ++dirties; });
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
    // Escape discards text without creating an automation edit.
    int before = begins[Start]; double previousStart = model->params[Start].load();
    SetFocus(startField); SetWindowTextW(startField, L"0.500 s"); SendMessageW(startField, WM_KEYDOWN, VK_ESCAPE, 0);
    assert(begins[Start] == before && model->params[Start].load() == previousStart && GetFocus() == parent);
    // The handle keeps the offset of the initial click, avoiding a boundary jump.
    model->params[Start].store(.2); model->params[End].store(.6);
    SendMessageW(window, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(210, 240));
    assert(std::abs(model->params[Start].load() - .2) < 1e-9);
    SendMessageW(window, WM_MOUSEMOVE, MK_LBUTTON, MAKELPARAM(254, 240));
    SendMessageW(window, WM_LBUTTONUP, 0, MAKELPARAM(254, 240));
    assert(std::abs(model->params[Start].load() - (.2 + 44.0 / 884)) < 1e-9);
    click(window, 786, 510); // Zoom in.
    // Horizontal scrolling moves the visible range in the reversed direction.
    model->params[Start].store(.5); model->params[End].store(.8);
    POINT wheel{470, 350}; ClientToScreen(window, &wheel);
    SendMessageW(window, WM_MOUSEHWHEEL, MAKEWPARAM(0, WHEEL_DELTA), MAKELPARAM(wheel.x, wheel.y));
    click(window, 100, 350);
    assert(std::abs(model->params[Start].load() - (.25 - .04 + 72.0 / 884 * .5)) < 1e-9);
    click(window, 470, 150); // Pan from overview.
    SendMessageW(window, WM_TIMER, 1, 0); UpdateWindow(window); capture(window, L"build/windows-sampler.bmp");
    click(window, 150, 90); click(window, 580, 163); click(window, 1200, 163);
    assert(model->params[DistEnabled].load() == 1 && model->params[ChorusEnabled].load() == 1);
    click(window, 800, 323); assert(changes[ChorusDepth] > 0);
    UpdateWindow(window); capture(window, L"build/windows-fx.bmp");
    const std::filesystem::path fixture = L"build/windows-\u97f3.wav"; writeFixture(fixture);
    editor.loadPath(fixture.wstring());
    ULONGLONG deadline = GetTickCount64() + 5000;
    while (model->loading.load() && GetTickCount64() < deadline) { SendMessageW(window, WM_TIMER, 1, 0); pump(); Sleep(1); }
    assert(!model->loading.load() && dirties == 1 && model->samples.snapshot()->frames() == 480);
    assert(model->params[Start].load() == 0 && model->params[End].load() == 1);
    std::filesystem::remove(fixture);
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
    SendMessageW(window, WM_KEYDOWN, 'A', 0); assert(model->notes.pop(note) && note.on);
    SendMessageW(window, WM_KEYDOWN, VK_CONTROL, 0);
    assert(model->notes.pop(note) && !note.on);
    standalone.detach();
    // Last-owner teardown unregisters the class; repeated fresh instances and
    // a parent-driven destruction must not retain a stale window procedure.
    for (int i = 0; i < 3; ++i) {
        WindowsEditor fresh(model, true); assert(fresh.attach(parent)); assert(fresh.nativeHandle()); fresh.detach();
    }
    {
        WindowsEditor first(model, true), second(model, true);
        assert(first.attach(parent)); assert(second.attach(parent)); first.detach();
        assert(IsWindow(static_cast<HWND>(second.nativeHandle())));
        DestroyWindow(parent); assert(!second.nativeHandle()); second.detach();
    }
    WNDCLASSEXW editorClass{}; editorClass.cbSize = sizeof(editorClass);
    assert(!GetClassInfoExW(wc.hInstance, L"EssentialSampler.Editor.0.7", &editorClass));
    UnregisterClassW(wc.lpszClassName, wc.hInstance);
    std::puts("Windows editor gesture, focus, lifecycle and rendering tests passed.");
}
