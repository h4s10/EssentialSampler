#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "WindowsEditor.hpp"
#include <windows.h>
#include <mmsystem.h>
#include <array>
#include <cstdint>
#include <thread>

namespace {
using namespace hasio;
// WinMM calls only signal an event. A single owned worker renders into prepared,
// fixed-size buffers; shutdown joins it before resetting or closing the device.
class AudioOutput {
    static constexpr size_t frames = 256, count = 4;
    struct Block { WAVEHDR header{}; std::array<int16_t, frames * 2> data{}; bool prepared = false, queued = false; };
    std::shared_ptr<Model> model;
    Engine engine;
    HWAVEOUT device = nullptr;
    HANDLE ready = nullptr, stopEvent = nullptr;
    std::array<Block, count> blocks{};
    std::thread thread;
    void render(Block& block) {
        engine.setSample(model->samples.pin()); engine.configure(model->settings());
        if (model->panic.exchange(false)) engine.allNotesOff();
        Note note; while (model->notes.pop(note)) engine.previewEvent(note);
        float peak = 0;
        for (size_t i = 0; i < frames; ++i) {
            float left = 0, right = 0; engine.render(left, right);
            if (!std::isfinite(left)) left = 0; if (!std::isfinite(right)) right = 0;
            peak = std::max({peak, std::abs(left), std::abs(right)});
            block.data[i * 2] = static_cast<int16_t>(std::lround(std::clamp(left, -1.f, 1.f) * 32767.f));
            block.data[i * 2 + 1] = static_cast<int16_t>(std::lround(std::clamp(right, -1.f, 1.f) * 32767.f));
        }
        model->meter.store(std::max(peak, model->meter.load() * .92f));
        model->activeVoices.store(engine.activeCount()); model->playhead.store(engine.playhead()); model->samples.unpin();
    }
    void run() {
        SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST);
        HANDLE events[] = {stopEvent, ready};
        for (;;) {
            if (WaitForSingleObject(stopEvent, 0) == WAIT_OBJECT_0) break;
            for (auto& block : blocks) if (!block.queued || (block.header.dwFlags & WHDR_DONE)) {
                if (WaitForSingleObject(stopEvent, 0) == WAIT_OBJECT_0) return;
                render(block);
                if (waveOutWrite(device, &block.header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) {
                    model->setStatus("Audio output stopped. Check the Windows default output device and reopen Essential Sampler."); return;
                }
                block.queued = true;
            }
            DWORD result = WaitForMultipleObjects(2, events, FALSE, INFINITE);
            if (result != WAIT_OBJECT_0 + 1) break;
        }
    }
public:
    explicit AudioOutput(std::shared_ptr<Model> m) : model(std::move(m)) {}
    ~AudioOutput() { stop(); }
    bool start() {
        engine.prepare(48000);
        ready = CreateEventW(nullptr, FALSE, FALSE, nullptr); stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!ready || !stopEvent) { stop(); return false; }
        WAVEFORMATEX format{}; format.wFormatTag = WAVE_FORMAT_PCM; format.nChannels = 2;
        format.nSamplesPerSec = 48000; format.wBitsPerSample = 16; format.nBlockAlign = 4; format.nAvgBytesPerSec = 192000;
        if (waveOutOpen(&device, WAVE_MAPPER, &format, reinterpret_cast<DWORD_PTR>(ready), 0, CALLBACK_EVENT) != MMSYSERR_NOERROR) {
            device = nullptr; stop(); return false;
        }
        for (auto& block : blocks) {
            block.header.lpData = reinterpret_cast<LPSTR>(block.data.data()); block.header.dwBufferLength = static_cast<DWORD>(sizeof(block.data));
            if (waveOutPrepareHeader(device, &block.header, sizeof(WAVEHDR)) != MMSYSERR_NOERROR) { stop(); return false; }
            block.prepared = true;
        }
        try { thread = std::thread([this] { run(); }); }
        catch (...) { stop(); return false; }
        return true;
    }
    void stop() {
        if (stopEvent) SetEvent(stopEvent);
        if (thread.joinable()) thread.join();
        if (device) {
            waveOutReset(device);
            for (auto& block : blocks) if (block.prepared) {
                waveOutUnprepareHeader(device, &block.header, sizeof(WAVEHDR)); block.prepared = false; block.queued = false;
            }
            waveOutClose(device); device = nullptr;
        }
        if (ready) { CloseHandle(ready); ready = nullptr; }
        if (stopEvent) { CloseHandle(stopEvent); stopEvent = nullptr; }
    }
};
struct Application {
    std::shared_ptr<Model> model = std::make_shared<Model>();
    WindowsEditor editor{model, false};
    AudioOutput audio{model};
    static LRESULT CALLBACK procedure(HWND window, UINT msg, WPARAM w, LPARAM l) {
        auto app = reinterpret_cast<Application*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (msg == WM_NCCREATE) {
            app = static_cast<Application*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
        }
        if (app) {
            if (msg == WM_SETFOCUS && app->editor.nativeHandle()) { SetFocus(static_cast<HWND>(app->editor.nativeHandle())); return 0; }
            if (msg == WM_ACTIVATE && LOWORD(w) == WA_INACTIVE) app->editor.stopNotes();
            if (msg == WM_CLOSE) { app->editor.detach(); app->audio.stop(); DestroyWindow(window); return 0; }
            if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
        }
        return DefWindowProcW(window, msg, w, l);
    }
};
} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    SetProcessDPIAware();
    Application app;
    WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.hInstance = instance; wc.lpfnWndProc = Application::procedure;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW); wc.hIcon = LoadIconW(nullptr, IDI_APPLICATION); wc.lpszClassName = L"EssentialSampler.Standalone.0.7";
    if (!RegisterClassExW(&wc)) return 1;
    constexpr DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    RECT bounds{0, 0, hasio::editorWidth, hasio::editorHeight}; AdjustWindowRectEx(&bounds, style, FALSE, 0);
    RECT work{}; SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    int width = bounds.right - bounds.left, height = bounds.bottom - bounds.top;
    HWND window = CreateWindowExW(0, wc.lpszClassName, L"Essential Sampler", style,
        std::max(work.left, work.left + (work.right - work.left - width) / 2),
        std::max(work.top, work.top + (work.bottom - work.top - height) / 2), width, height,
        nullptr, nullptr, instance, &app);
    if (!window) return 1;
    if (!app.editor.attach(window)) { DestroyWindow(window); return 1; }
    if (!app.audio.start()) app.model->setStatus("Audio output unavailable. Check the Windows default output device.");
    ShowWindow(window, show); UpdateWindow(window); SetFocus(static_cast<HWND>(app.editor.nativeHandle()));
    MSG msg{}; int result;
    while ((result = GetMessageW(&msg, nullptr, 0, 0)) > 0) { TranslateMessage(&msg); DispatchMessageW(&msg); }
    app.editor.detach(); app.audio.stop(); UnregisterClassW(wc.lpszClassName, instance);
    return result < 0 ? 1 : static_cast<int>(msg.wParam);
}
