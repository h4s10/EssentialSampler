#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include "WindowsEditor.hpp"
#include "AudioFile.hpp"
#include <windows.h>
#include <windowsx.h>
#include <commdlg.h>
#include <shellapi.h>
#include <array>
#include <cstdio>
#include <cwchar>
#include <cwctype>
#include <exception>
#include <thread>
#include <utility>

namespace hasio {
namespace {
constexpr wchar_t editorClass[] = L"EssentialSampler.Editor.0.7";
constexpr wchar_t ownerProperty[] = L"EssentialSampler.EditOwner";
constexpr wchar_t procProperty[] = L"EssentialSampler.EditProc";
constexpr UINT_PTR refreshTimer = 1;
struct EditorClassRegistration { std::mutex mutex; size_t owners = 0; } classRegistration;
constexpr unsigned blue = 0x0a84ff, foreground = 0xf2f2f5, muted = 0xa3a3aa;
constexpr uint32_t sliderParams[] = { Tune, FadeIn, FadeOut, Attack, Release };
constexpr uint32_t fxParams[] = { DistAmount, DistTone, DistMix, ChorusDepth,
    ChorusRate, ChorusWidth, ChorusDelay, ChorusFeedback, ChorusMix };
constexpr const wchar_t* fxLabels[] = { L"Amount", L"Tone", L"Mix", L"Depth",
    L"Rate", L"Width", L"Delay", L"Feedback", L"Mix" };
struct Rect {
    double x, y, w, h;
    bool contains(POINT p) const { return p.x >= x && p.x < x + w && p.y >= y && p.y < y + h; }
    RECT native() const { return {static_cast<LONG>(std::lround(x)), static_cast<LONG>(std::lround(y)),
        static_cast<LONG>(std::lround(x + w)), static_cast<LONG>(std::lround(y + h))}; }
};
Rect overview() { return {28, 126, 884, 54}; }
Rect detail() { return {28, 218, 884, 255}; }
Rect keyboard() { return {146, 752, 946, 76}; }
Rect loadButton() { return {1080, 37, 172, 40}; }
Rect tabButton(int i) { return {28.0 + i * 83, 78, 80, 28}; }
Rect fxToggle(int i) { return {i ? 1182.0 : 558.0, 150, 46, 26}; }
Rect fxSlider(int i) {
    if (i < 3) return {52, 310.0 + i * 100, 548, 26};
    i -= 3; return {676.0 + (i % 2) * 298, 310.0 + (i / 2) * 100, 254, 26};
}
Rect sliderRow(int i) {
    constexpr Rect rows[] = {{968, 194, 284, 26}, {125, 660, 169, 26}, {125, 701, 169, 26},
        {518, 660, 169, 26}, {518, 701, 169, 26}};
    return rows[i];
}
Rect speedButton() { return {1206, 338, 46, 26}; }
Rect outputKnob() { return {819, 650, 80, 76}; }
Rect rateSlider() { return {968, 424, 284, 26}; }
Rect modeButton(int i) { return {28 + 884.0 / 5 * i, 541, 884.0 / 5, 38}; }
Rect zoomButton(int i) { return {718.0 + i * 62, 495, i == 2 ? 70.0 : 52.0, 32}; }
Rect octaveButton(int i) { return {28.0 + i * 44, 782, 43, 32}; }
Rect rootButton() { return {1134, 242, 118, 32}; }
Rect lengthButton() { return {1148, 472, 104, 32}; }
Rect syncButton(int i) { return {968.0 + i * 79, 472, 79, 32}; }
Rect typeButton() { return {410, 211, 194, 32}; }
Rect loopTag(double x, double otherX, bool end) {
    double left = std::clamp(x - 14, detail().x, detail().x + detail().w - 28);
    double otherLeft = std::clamp(otherX - 14, detail().x, detail().x + detail().w - 28);
    return {left, detail().y + (end && std::abs(left - otherLeft) < 32 ? 40 : 10), 28, 24};
}
std::wstring wide(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring value(static_cast<size_t>(n), L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), value.data(), n);
    return value;
}
std::string utf8(const std::wstring& s) {
    if (s.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0, nullptr, nullptr);
    std::string value(static_cast<size_t>(n), '\0');
    if (n) WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), value.data(), n, nullptr, nullptr);
    return value;
}
template<class... T> std::wstring format(const wchar_t* pattern, T... args) {
    wchar_t text[256]{}; std::swprintf(text, std::size(text), pattern, args...); return text;
}
std::wstring valueText(uint32_t id, double value) {
    double v = plain(id, value);
    if (id == Root) {
        const wchar_t* names[] = {L"C", L"C#", L"D", L"D#", L"E", L"F", L"F#", L"G", L"G#", L"A", L"A#", L"B"};
        int n = static_cast<int>(v); return format(L"%ls%d · %d", names[n % 12], n / 12 - 1, n);
    }
    if (id == Gain) return format(L"%+.1f dB", v);
    if (id == Tune) return format(L"%+.1f st", v);
    return format(L"%.1f ms", v);
}
bool isBlack(int n) { n %= 12; return n == 1 || n == 3 || n == 6 || n == 8 || n == 10; }
Rect keyRect(int pitch, int base) {
    auto r = keyboard(); double w = r.w / 15;
    int whites = 0; for (int p = base; p < pitch; ++p) if (!isBlack(p)) ++whites;
    if (isBlack(pitch)) return {r.x + whites * w - w * .32, r.y, w * .64, r.h * .62};
    return {r.x + whites * w, r.y, w - 1, r.h};
}
int hitKey(POINT p, int base) {
    if (!keyboard().contains(p)) return -1;
    for (int pass = 1; pass >= 0; --pass)
        for (int n = base; n <= base + 24; ++n)
            if (isBlack(n) == (pass != 0) && keyRect(n, base).contains(p)) return n;
    return -1;
}
bool modifiers() { return (GetKeyState(VK_CONTROL) | GetKeyState(VK_MENU) | GetKeyState(VK_SHIFT)
    | GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000; }
bool modifierKey(WPARAM key) { return key == VK_CONTROL || key == VK_MENU || key == VK_SHIFT || key == VK_LWIN || key == VK_RWIN; }
COLORREF colour(unsigned rgb) { return RGB((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }
void box(HDC dc, Rect r, unsigned fill, int radius = 8, unsigned border = 0) {
    HBRUSH brush = CreateSolidBrush(colour(fill));
    HPEN pen = CreatePen(PS_SOLID, 1, colour(border ? border : fill));
    auto oldBrush = SelectObject(dc, brush); auto oldPen = SelectObject(dc, pen); auto q = r.native();
    RoundRect(dc, q.left, q.top, q.right, q.bottom, radius * 2, radius * 2);
    SelectObject(dc, oldPen); SelectObject(dc, oldBrush); DeleteObject(pen); DeleteObject(brush);
}
void line(HDC dc, double x1, double y1, double x2, double y2, unsigned rgb, int width = 1) {
    HPEN pen = CreatePen(PS_SOLID, width, colour(rgb)); auto old = SelectObject(dc, pen);
    MoveToEx(dc, static_cast<int>(std::lround(x1)), static_cast<int>(std::lround(y1)), nullptr);
    LineTo(dc, static_cast<int>(std::lround(x2)), static_cast<int>(std::lround(y2)));
    SelectObject(dc, old); DeleteObject(pen);
}
void clip(HDC dc, Rect r) { auto q = r.native(); IntersectClipRect(dc, q.left, q.top, q.right, q.bottom); }
// Use the module containing this code, not the host executable, for class lifetime.
HINSTANCE moduleInstance() {
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(&moduleInstance), &module);
    return module;
}
} // namespace

struct WindowsEditor::Impl {
    std::shared_ptr<Model> model;
    bool hosted = false, fxTab = false, detached = true, committing = false, ownsClass = false;
    HWND window = nullptr, previousFocus = nullptr, skipKillFocus = nullptr;
    std::array<HWND, 4> fields{};
    std::array<HFONT, 32> regular{}, bold{};
    HBRUSH fieldBrush = nullptr;
    std::function<void(uint32_t)> begin, end;
    std::function<void(uint32_t, double)> change;
    std::function<void()> dirty;
    double viewStart = 0, viewLength = 1, anchor = 0, panStart = 0, loopStart = 0, loopEnd = 1, knobStart = 0, handleOffset = 0;
    int drag = 0, slider = -1, mouseNote = -1, keyboardBase = 48, lastSyncLength = 3;
    std::array<int, 256> keyboardNotes{};
    std::array<bool, 128> held{};
    ULONGLONG gestureDistance = 0;
    POINT gesturePosition{};
    struct LoadJob {
        std::atomic<bool> complete{false};
        std::shared_ptr<Sample> sample;
        std::string error;
    };
    std::shared_ptr<LoadJob> job;
    std::thread loader;

    Impl(std::shared_ptr<Model> m, bool h) : model(std::move(m)), hosted(h) { keyboardNotes.fill(-1); }
    ~Impl() {
        detach();
        for (HFONT f : regular) if (f) DeleteObject(f);
        for (HFONT f : bold) if (f) DeleteObject(f);
        if (fieldBrush) DeleteObject(fieldBrush);
    }
    HFONT font(int size, bool heavy = false) {
        size = std::clamp(size, 1, 31); auto& f = (heavy ? bold : regular)[size];
        if (!f) f = CreateFontW(-size, 0, 0, 0, heavy ? FW_SEMIBOLD : FW_NORMAL, FALSE, FALSE, FALSE,
            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
        return f;
    }
    void label(HDC dc, const std::wstring& text, Rect r, int size = 12, unsigned rgb = muted, bool heavy = false, UINT align = DT_LEFT) {
        auto old = SelectObject(dc, font(size, heavy)); auto q = r.native();
        SetTextColor(dc, colour(rgb)); SetBkMode(dc, TRANSPARENT);
        DrawTextW(dc, text.c_str(), static_cast<int>(text.size()), &q, align | DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS | DT_NOPREFIX);
        SelectObject(dc, old);
    }
    void button(HDC dc, Rect r, const std::wstring& text, bool active = false, bool enabled = true) {
        box(dc, r, active ? 0x505055 : 0x29292c, 8, 0x444449);
        label(dc, text, {r.x + 4, r.y, r.w - 8, r.h}, 14, enabled ? foreground : 0x72727a, active, DT_CENTER);
    }
    void pill(HDC dc, const std::wstring& text, Rect r) {
        box(dc, r, 0x29292c, 8, 0x444448); label(dc, text, r, 16, foreground, false, DT_CENTER);
    }
    void drawSlider(HDC dc, Rect r, double value, bool enabled = true) {
        double y = r.y + r.h * .5;
        box(dc, {r.x, y - 2, r.w, 4}, 0x515155, 2);
        if (enabled) box(dc, {r.x, y - 2, std::max(2.0, r.w * value), 4}, blue, 2);
        box(dc, {r.x + r.w * value - 8, y - 8, 16, 16}, enabled ? 0xe7e7e9 : 0x77777b, 8);
    }
    void toggle(HDC dc, Rect r, bool on) {
        box(dc, r, on ? blue : 0x4c4c51, 13);
        box(dc, {r.x + (on ? 22 : 3), r.y + 3, 20, 20}, 0xf5f5f7, 10);
    }
    void invalidate() { if (window) InvalidateRect(window, nullptr, FALSE); }
    void edit(uint32_t id, double value) {
        value = norm(value);
        if (id == Root || id == ModeId || id == KeepSpeed || id == SyncLength || id == DistType || id == DistEnabled || id == ChorusEnabled)
            value = normalized(id, plain(id, value));
        model->params[id].store(value); if (change) change(id, value); invalidate();
    }
    void singleEdit(uint32_t id, double value) { if (begin) begin(id); edit(id, value); if (end) end(id); }
    void releaseMouseNote() {
        if (mouseNote >= 0) { model->preview(mouseNote, false); held[mouseNote] = false; mouseNote = -1; }
    }
    void stopKeyboardNotes() {
        for (int& note : keyboardNotes) if (note >= 0) { model->preview(note, false); held[note] = false; note = -1; }
    }
    void stopNotes() {
        for (int n = 0; n < 128; ++n) if (held[n]) { model->preview(n, false); held[n] = false; }
        keyboardNotes.fill(-1); mouseNote = -1; model->stopPreviewNotes(); invalidate();
    }
    void finishGesture() {
        int previous = std::exchange(drag, 0), previousSlider = std::exchange(slider, -1);
        if (end) {
            if (previous == 1 || previous == 3) end(Start);
            if (previous == 2 || previous == 3) end(End);
            if (previous == 5 && previousSlider >= 0) end(sliderParams[previousSlider]);
            if (previous == 8) end(Gain);
            if (previous == 9) end(PlaybackRate);
            if (previous == 10 && previousSlider >= 0) end(fxParams[previousSlider]);
        }
        releaseMouseNote();
        if (window && GetCapture() == window) ReleaseCapture();
    }
    void releaseFocus() {
        HWND focused = GetFocus();
        if (focused != window && (!window || !IsChild(window, focused))) return;
        if (!hosted) { SetFocus(window); return; }
        HWND target = IsWindow(previousFocus) && previousFocus != window && !IsChild(window, previousFocus)
            ? previousFocus : GetParent(window);
        if (target) SetFocus(target);
    }
    void detach() {
        if (!detached) { finishGesture(); stopNotes(); detached = true; }
        // The thread must exit before a host can unload the plugin DLL. The
        // result is never posted to a possibly recycled HWND or destroyed editor.
        if (loader.joinable()) loader.join();
        if (job) { model->loading.store(false); job.reset(); }
        if (window) { HWND old = window; KillTimer(old, refreshTimer); DragAcceptFiles(old, FALSE); DestroyWindow(old); window = nullptr; }
        if (ownsClass) {
            std::lock_guard<std::mutex> lock(classRegistration.mutex);
            if (--classRegistration.owners == 0) UnregisterClassW(editorClass, moduleInstance());
            ownsClass = false;
        }
        fields.fill(nullptr); begin = {}; change = {}; end = {}; dirty = {};
    }
    bool attach(HWND parent) {
        if (window) return GetParent(window) == parent;
        if (!parent || !IsWindow(parent)) return false;
        WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.style = CS_DBLCLKS;
        wc.lpfnWndProc = windowProc; wc.hInstance = moduleInstance(); wc.hCursor = LoadCursorW(nullptr, IDC_ARROW); wc.lpszClassName = editorClass;
        if (!ownsClass) {
            std::lock_guard<std::mutex> lock(classRegistration.mutex);
            if (!classRegistration.owners && !RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;
            ++classRegistration.owners; ownsClass = true;
        }
        detached = false;
        window = CreateWindowExW(WS_EX_CONTROLPARENT, editorClass, L"Essential Sampler sample editor",
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS, 0, 0, editorWidth, editorHeight,
            parent, nullptr, wc.hInstance, this);
        if (!window) { detach(); return false; }
        const Rect locations[] = {{76, 496, 102, 30}, {236, 496, 102, 30}, {416, 496, 102, 30}, {1153, 526, 99, 28}};
        fieldBrush = fieldBrush ? fieldBrush : CreateSolidBrush(colour(0x29292c));
        for (int i = 0; i < 4; ++i) {
            auto r = locations[i]; fields[i] = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                WS_CHILD | WS_VISIBLE | ES_CENTER | ES_AUTOHSCROLL, static_cast<int>(r.x), static_cast<int>(r.y), static_cast<int>(r.w), static_cast<int>(r.h),
                window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(100 + i)), wc.hInstance, nullptr);
            if (!fields[i]) { detach(); return false; }
            SendMessageW(fields[i], WM_SETFONT, reinterpret_cast<WPARAM>(font(13)), TRUE);
            SendMessageW(fields[i], EM_SETLIMITTEXT, 64, 0);
            SetPropW(fields[i], ownerProperty, this);
            auto previous = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(fields[i], GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(fieldProc)));
            SetPropW(fields[i], procProperty, reinterpret_cast<HANDLE>(previous));
            if (fxTab) ShowWindow(fields[i], SW_HIDE);
        }
        DragAcceptFiles(window, TRUE);
        GESTURECONFIG gc[] = {{GID_ZOOM, GC_ZOOM, 0}, {GID_PAN, GC_PAN_WITH_SINGLE_FINGER_HORIZONTALLY | GC_PAN_WITH_INERTIA, GC_PAN_WITH_SINGLE_FINGER_VERTICALLY}};
        SetGestureConfig(window, 0, 2, gc, sizeof(GESTURECONFIG));
        SetTimer(window, refreshTimer, 33, nullptr); refreshFields(); return true;
    }
    static LRESULT CALLBACK fieldProc(HWND field, UINT msg, WPARAM w, LPARAM l) {
        auto self = static_cast<Impl*>(GetPropW(field, ownerProperty));
        auto old = reinterpret_cast<WNDPROC>(GetPropW(field, procProperty));
        if (!old) return DefWindowProcW(field, msg, w, l);
        if (self) {
            if (msg == WM_LBUTTONDOWN) {
                HWND focus = GetFocus();
                if (focus != self->window && !IsChild(self->window, focus)) self->previousFocus = focus;
            }
            if (msg == WM_SETFOCUS) self->stopNotes();
            if (msg == WM_GETDLGCODE) return DLGC_WANTCHARS | DLGC_WANTARROWS | DLGC_WANTALLKEYS;
            if (msg == WM_KEYDOWN && (w == VK_RETURN || w == VK_ESCAPE)) {
                if (w == VK_RETURN) self->commitField(field);
                else self->refreshFields(field);
                self->skipKillFocus = field;
                self->releaseFocus(); return 0;
            }
            if (msg == WM_CHAR && (w == VK_RETURN || w == VK_ESCAPE)) return 0;
        }
        LRESULT result = CallWindowProcW(old, field, msg, w, l);
        if (msg == WM_NCDESTROY) { RemovePropW(field, ownerProperty); RemovePropW(field, procProperty); }
        return result;
    }
    void setField(HWND field, const std::wstring& text, HWND force) {
        if (GetFocus() == field && force != field) return;
        wchar_t old[128]{}; GetWindowTextW(field, old, 128);
        if (text != old) SetWindowTextW(field, text.c_str());
    }
    void refreshFields(HWND force = nullptr) {
        if (detached || !fields[0]) return;
        auto sample = model->samples.snapshot(); double seconds = sample ? sample->frames() / sample->rate : 0;
        double start = model->params[Start].load(), finish = model->params[End].load();
        double values[] = {start * seconds, finish * seconds, std::max(0.0, finish - start) * seconds};
        for (int i = 0; i < 3; ++i) {
            EnableWindow(fields[i], seconds > 0); setField(fields[i], format(L"%.3f s", values[i]), force);
        }
        EnableWindow(fields[3], !model->hostTempoValid.load());
        setField(fields[3], format(L"%.1f", model->settings().tempo), force);
        int selected = static_cast<int>(plain(SyncLength, model->params[SyncLength].load()));
        if (selected > 0) lastSyncLength = selected;
    }
    void commitField(HWND field) {
        if (committing || detached) return;
        committing = true;
        int index = GetDlgCtrlID(field) - 100;
        wchar_t text[128]{}; GetWindowTextW(field, text, 128);
        wchar_t* rest = nullptr; double value = std::wcstod(text, &rest);
        bool valid = rest != text && std::isfinite(value);
        while (std::iswspace(*rest)) ++rest;
        if (index < 3 && *rest == L's') ++rest;
        while (std::iswspace(*rest)) ++rest;
        valid = valid && *rest == L'\0';
        if (valid && index == 3 && !model->hostTempoValid.load()) singleEdit(Tempo, normalized(Tempo, value));
        auto sample = model->samples.snapshot();
        if (valid && index >= 0 && index < 3 && sample && sample->frames() >= 2) {
            double gap = 2.0 / sample->frames(), v = value / (sample->frames() / sample->rate);
            double start = std::clamp(norm(model->params[Start].load()), 0.0, 1 - gap);
            double finish = std::clamp(norm(model->params[End].load()), start + gap, 1.0);
            if (index == 0) start = std::clamp(v, 0.0, finish - gap);
            else if (index == 1) finish = std::clamp(v, start + gap, 1.0);
            else finish = std::clamp(start + v, start + gap, 1.0);
            singleEdit(Start, start); singleEdit(End, finish);
        }
        refreshFields(field); committing = false;
    }
    void loadPath(const std::wstring& path) {
        if (detached || path.empty() || model->loading.exchange(true)) return;
        std::string file = utf8(path);
        if (file.empty()) { model->loading.store(false); model->setStatus("The file name is not valid Unicode."); return; }
        if (loader.joinable()) loader.join();
        job = std::make_shared<LoadJob>(); auto work = job;
        try {
            loader = std::thread([work, file = std::move(file)] {
                try { work->sample = loadAudioFile(file, work->error); }
                catch (const std::exception& e) { work->error = std::string("Could not load audio: ") + e.what(); }
                catch (...) { work->error = "Could not load audio."; }
                work->complete.store(true, std::memory_order_release);
            });
        } catch (...) { job.reset(); model->loading.store(false); model->setStatus("Could not start the audio decoder."); }
        invalidate();
    }
    void completeLoad() {
        if (!job || !job->complete.load(std::memory_order_acquire)) return;
        if (loader.joinable()) loader.join();
        auto completed = std::move(job);
        if (completed->sample) {
            finishGesture(); stopNotes(); model->samples.publish(std::move(completed->sample)); model->panic.store(true); model->setStatus("");
            singleEdit(Start, 0); singleEdit(End, 1); viewStart = 0; viewLength = 1;
            if (dirty) dirty();
        } else model->setStatus(completed->error.empty() ? "The audio file could not be loaded." : completed->error);
        model->loading.store(false); refreshFields(); invalidate();
    }
    void openFile() {
        stopNotes(); finishGesture();
        std::array<wchar_t, 32768> file{}; OPENFILENAMEW dialog{}; dialog.lStructSize = sizeof(dialog);
        dialog.hwndOwner = GetAncestor(window, GA_ROOT); dialog.lpstrFile = file.data(); dialog.nMaxFile = static_cast<DWORD>(file.size());
        dialog.lpstrFilter = L"Audio samples (*.wav;*.aif;*.aiff;*.flac)\0*.wav;*.aif;*.aiff;*.flac\0All files\0*.*\0\0";
        dialog.lpstrTitle = L"Load a mono or stereo sample"; dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR | OFN_EXPLORER;
        if (GetOpenFileNameW(&dialog)) loadPath(file.data());
        releaseFocus();
    }
    void popup(Rect r, uint32_t id) {
        finishGesture(); stopNotes();
        HMENU menu = CreatePopupMenu(); if (!menu) return;
        int count = id == Root ? 128 : id == DistType ? 6 : lengthCount - 1;
        int selected = static_cast<int>(plain(id, model->params[id].load()));
        for (int i = 0; i < count; ++i) {
            int value = id == SyncLength ? i + 1 : i;
            std::wstring text = id == Root ? valueText(Root, normalized(Root, value)) : wide(id == DistType ? distortionNames[i] : lengthNames[value]);
            AppendMenuW(menu, MF_STRING | (selected == value ? MF_CHECKED : 0) | (id == Root && i > 0 && i % 24 == 0 ? MF_MENUBARBREAK : 0), i + 1, text.c_str());
        }
        POINT point{static_cast<LONG>(r.x), static_cast<LONG>(r.y + r.h)}; ClientToScreen(window, &point);
        UINT choice = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_LEFTALIGN | TPM_TOPALIGN,
            point.x, point.y, window, nullptr);
        DestroyMenu(menu);
        if (choice) singleEdit(id, normalized(id, id == SyncLength ? choice : choice - 1));
        refreshFields(); releaseFocus();
    }
    void showFx(bool enabled) {
        finishGesture(); releaseFocus(); fxTab = enabled;
        for (HWND field : fields) ShowWindow(field, enabled ? SW_HIDE : SW_SHOWNA);
        invalidate();
    }
    double timeAt(double x) const { return norm(viewStart + (x - detail().x) / detail().w * viewLength); }
    void zoom(double factor, double x) {
        auto sample = model->samples.snapshot(); double minimum = sample && sample->frames() ? std::min(1.0, 32.0 / sample->frames()) : .001;
        double position = std::clamp((x - detail().x) / detail().w, 0.0, 1.0);
        double length = std::clamp(viewLength / std::max(.01, factor), minimum, 1.0);
        viewStart = std::clamp(viewStart + position * (viewLength - length), 0.0, 1 - length); viewLength = length; invalidate();
    }
    void startDrag(int kind, int index = -1) {
        drag = kind; slider = index; SetCapture(window);
        if (!begin) return;
        if (kind == 1 || kind == 3) begin(Start);
        if (kind == 2 || kind == 3) begin(End);
        if (kind == 5) begin(sliderParams[index]);
        if (kind == 8) begin(Gain);
        if (kind == 9) begin(PlaybackRate);
        if (kind == 10) begin(fxParams[index]);
    }
    void mouseDown(POINT p, bool doubleClick) {
        finishGesture(); if (hosted) releaseFocus(); else SetFocus(window);
        if (loadButton().contains(p)) { openFile(); return; }
        for (int i = 0; i < 2; ++i) if (octaveButton(i).contains(p)) {
            stopNotes(); keyboardBase = std::clamp(keyboardBase + (i ? 12 : -12), 0, 96); return;
        }
        if (outputKnob().contains(p)) {
            if (doubleClick) { singleEdit(Gain, defaults[Gain]); return; }
            anchor = p.y; knobStart = model->params[Gain].load(); startDrag(8); return;
        }
        int key = hitKey(p, keyboardBase);
        if (key >= 0) { startDrag(6); mouseNote = key; held[key] = true; model->preview(key, true); invalidate(); return; }
        for (int i = 0; i < 2; ++i) if (tabButton(i).contains(p)) { showFx(i == 1); return; }
        if (fxTab) {
            if (typeButton().contains(p)) { popup(typeButton(), DistType); return; }
            for (int i = 0; i < 2; ++i) if (fxToggle(i).contains(p)) {
                auto id = i ? ChorusEnabled : DistEnabled; singleEdit(id, model->params[id].load() >= .5 ? 0 : 1); return;
            }
            for (int i = 0; i < 9; ++i) if (fxSlider(i).contains(p)) {
                if (doubleClick) singleEdit(fxParams[i], defaults[fxParams[i]]);
                else { startDrag(10, i); mouseMove(p); } return;
            }
            return;
        }
        if (rootButton().contains(p)) { popup(rootButton(), Root); return; }
        if (lengthButton().contains(p) && plain(SyncLength, model->params[SyncLength].load()) > 0) { popup(lengthButton(), SyncLength); return; }
        for (int i = 0; i < 2; ++i) if (syncButton(i).contains(p)) { singleEdit(SyncLength, normalized(SyncLength, i ? lastSyncLength : 0)); refreshFields(); return; }
        if (speedButton().contains(p)) {
            if (plain(SyncLength, model->params[SyncLength].load()) == 0) singleEdit(KeepSpeed, model->params[KeepSpeed].load() >= .5 ? 0 : 1); return;
        }
        if (rateSlider().contains(p)) {
            if (plain(SyncLength, model->params[SyncLength].load()) > 0) return;
            if (doubleClick) singleEdit(PlaybackRate, defaults[PlaybackRate]); else { startDrag(9); mouseMove(p); } return;
        }
        for (int i = 0; i < 5; ++i) if (modeButton(i).contains(p)) { singleEdit(ModeId, i / 4.0); return; }
        for (int i = 0; i < 3; ++i) if (zoomButton(i).contains(p)) {
            if (i == 2) { viewStart = 0; viewLength = 1; invalidate(); }
            else zoom(i == 0 ? .5 : 2, detail().x + detail().w * .5); return;
        }
        for (int i = 0; i < 5; ++i) if (sliderRow(i).contains(p)) {
            if (doubleClick) singleEdit(sliderParams[i], defaults[sliderParams[i]]); else { startDrag(5, i); mouseMove(p); } return;
        }
        if (overview().contains(p)) { startDrag(4); mouseMove(p); return; }
        if (detail().contains(p)) {
            if (doubleClick) { viewStart = 0; viewLength = 1; invalidate(); return; }
            if (GetKeyState(VK_SHIFT) & 0x8000) { anchor = p.x; panStart = viewStart; startDrag(7); return; }
            double sx = detail().x + (model->params[Start].load() - viewStart) / viewLength * detail().w;
            double ex = detail().x + (model->params[End].load() - viewStart) / viewLength * detail().w;
            loopStart = norm(model->params[Start].load()); loopEnd = norm(model->params[End].load()); handleOffset = 0;
            int kind;
            if (sx >= detail().x && sx <= detail().x + detail().w && loopTag(sx, ex, false).contains(p)) { kind = 1; handleOffset = timeAt(p.x) - loopStart; }
            else if (ex >= detail().x && ex <= detail().x + detail().w && loopTag(ex, sx, true).contains(p)) { kind = 2; handleOffset = timeAt(p.x) - loopEnd; }
            else if (p.x < sx) kind = 1;
            else if (p.x > ex) kind = 2;
            else { kind = 3; anchor = timeAt(p.x); }
            startDrag(kind); if (kind == 1 || kind == 2) mouseMove(p);
        }
    }
    void mouseMove(POINT p) {
        if (!drag) return;
        auto sample = model->samples.snapshot(); double gap = sample && sample->frames() >= 2 ? 2.0 / sample->frames() : .0001;
        double t = timeAt(p.x);
        if (drag == 1) edit(Start, std::min(t - handleOffset, std::max(0.0, model->params[End].load() - gap)));
        if (drag == 2) edit(End, std::max(t - handleOffset, std::min(1.0, model->params[Start].load() + gap)));
        if (drag == 3) {
            double delta = std::clamp(t - anchor, -loopStart, 1 - loopEnd);
            edit(Start, loopStart + delta); edit(End, loopEnd + delta);
        }
        if (drag == 4) viewStart = std::clamp((p.x - overview().x) / overview().w - viewLength * .5, 0.0, 1 - viewLength);
        if (drag == 5 && slider >= 0) { auto r = sliderRow(slider); edit(sliderParams[slider], (p.x - r.x) / r.w); }
        if (drag == 6) {
            int key = hitKey(p, keyboardBase);
            if (key != mouseNote) { releaseMouseNote(); mouseNote = key; if (key >= 0) { model->preview(key, true); held[key] = true; } }
        }
        if (drag == 7) viewStart = std::clamp(panStart - (p.x - anchor) / detail().w * viewLength, 0.0, 1 - viewLength);
        if (drag == 8) edit(Gain, knobStart + (anchor - p.y) / ((GetKeyState(VK_SHIFT) & 0x8000) ? 1200 : 180));
        if (drag == 9) edit(PlaybackRate, (p.x - rateSlider().x) / rateSlider().w);
        if (drag == 10 && slider >= 0) { auto r = fxSlider(slider); edit(fxParams[slider], (p.x - r.x) / r.w); }
        invalidate();
    }
    bool keyDown(WPARAM key, LPARAM flags) {
        if (modifierKey(key)) { stopKeyboardNotes(); return false; }
        if (hosted || detached || modifiers() || key >= keyboardNotes.size()) return false;
        constexpr WPARAM keys[] = {'A', 'W', 'S', 'E', 'D', 'F', 'T', 'G', 'Y', 'H', 'U', 'J', 'K', 'O', 'L', 'P', VK_OEM_1};
        int index = -1; for (int i = 0; i < static_cast<int>(std::size(keys)); ++i) if (key == keys[i]) index = i;
        if (index < 0) return false;
        if (flags & (1LL << 30)) return keyboardNotes[key] >= 0;
        int pitch = std::min(127, keyboardBase + 12 + index);
        if (keyboardNotes[key] < 0 && !held[pitch]) { keyboardNotes[key] = pitch; held[pitch] = true; model->preview(pitch, true); invalidate(); }
        return true;
    }
    bool keyUp(WPARAM key) {
        if (key >= keyboardNotes.size() || keyboardNotes[key] < 0) return false;
        int pitch = std::exchange(keyboardNotes[key], -1); held[pitch] = false; model->preview(pitch, false); invalidate(); return !modifiers();
    }
    void drawWave(HDC dc, const Sample& sample, Rect r, double start, double length, unsigned rgb) {
        int saved = SaveDC(dc); clip(dc, r); HPEN pen = CreatePen(PS_SOLID, 1, colour(rgb)); auto old = SelectObject(dc, pen);
        double mid = r.y + r.h * .5, amplitude = r.h * .44;
        for (int x = 0; x < static_cast<int>(r.w); ++x) {
            size_t a = static_cast<size_t>(std::max(0.0, (start + x / r.w * length) * sample.frames()));
            size_t b = static_cast<size_t>(std::max(0.0, (start + (x + 1) / r.w * length) * sample.frames()));
            auto peak = sample.peak(a, b);
            MoveToEx(dc, static_cast<int>(r.x) + x, static_cast<int>(mid - peak.hi * amplitude), nullptr);
            LineTo(dc, static_cast<int>(r.x) + x, static_cast<int>(mid - peak.lo * amplitude) + 1);
        }
        SelectObject(dc, old); DeleteObject(pen); RestoreDC(dc, saved);
    }
    void drawFx(HDC dc) {
        box(dc, {28, 126, 600, 453}, 0x202023, 14, 0x37373d); box(dc, {652, 126, 600, 453}, 0x202023, 14, 0x37373d);
        label(dc, L"Distortion", {52, 148, 360, 30}, 23, foreground, true); label(dc, L"Chorus", {676, 148, 360, 30}, 23, foreground, true);
        label(dc, L"Harmonics, texture and colour", {52, 184, 480, 22}, 14); label(dc, L"Movement and stereo space", {676, 184, 480, 22}, 14);
        label(dc, L"Type", {52, 216, 130, 24}, 16, 0xe0e0e5); label(dc, L"Stereo modulated delay", {676, 218, 500, 20}, 13, 0x85858f);
        button(dc, typeButton(), wide(distortionNames[static_cast<int>(plain(DistType, model->params[DistType].load()))]) + L"  ▾");
        for (int i = 0; i < 2; ++i) toggle(dc, fxToggle(i), model->params[i ? ChorusEnabled : DistEnabled].load() >= .5);
        for (int i = 0; i < 9; ++i) {
            auto r = fxSlider(i); auto id = fxParams[i]; double v = plain(id, model->params[id].load());
            label(dc, fxLabels[i], {r.x, r.y - 39, r.w - 100, 24}, 16, 0xe0e0e5);
            auto text = id == ChorusRate ? format(L"%.2f Hz", v) : id == ChorusDelay ? format(L"%.1f ms", v) : format(L"%.0f %%", v);
            pill(dc, text, {r.x + r.w - 94, r.y - 44, 94, 32}); drawSlider(dc, r, model->params[id].load());
        }
        label(dc, L"Dark", {52, 442, 120, 18}, 11, 0x85858f); label(dc, L"Bright", {480, 442, 120, 18}, 11, 0x85858f, false, DT_RIGHT);
        label(dc, L"Double-click a slider to reset", {52, 551, 548, 18}, 11, 0x85858f); label(dc, L"Width controls the wet signal", {676, 551, 548, 18}, 11, 0x85858f);
    }
    void drawSampler(HDC dc, const std::shared_ptr<const Sample>& sample) {
        auto ov = overview(), dt = detail(); double start = model->params[Start].load(), finish = model->params[End].load();
        box(dc, ov, 0x202023, 8, 0x3b3b40);
        box(dc, {ov.x + start * ov.w, ov.y + 1, (finish - start) * ov.w, ov.h - 2}, 0x20354b, 0);
        if (sample) drawWave(dc, *sample, {ov.x + 4, ov.y + 4, ov.w - 8, ov.h - 8}, 0, 1, 0x77777e);
        if (viewLength < .999) {
            auto visible = Rect{ov.x + viewStart * ov.w, ov.y + 1, viewLength * ov.w, ov.h - 2};
            auto q = visible.native(); HBRUSH brush = CreateSolidBrush(colour(0xbabac2)); FrameRect(dc, &q, brush); DeleteObject(brush);
        }
        double sx = dt.x + (start - viewStart) / viewLength * dt.w, ex = dt.x + (finish - viewStart) / viewLength * dt.w;
        int saved = SaveDC(dc); clip(dc, dt);
        box(dc, {sx, dt.y, std::max(0.0, ex - sx), dt.h}, 0x1c2a3d, 0);
        for (int i = 0; i <= 8; ++i) line(dc, dt.x + dt.w * i / 8, dt.y, dt.x + dt.w * i / 8, dt.y + dt.h, 0x353539);
        line(dc, dt.x, dt.y + dt.h / 2, dt.x + dt.w, dt.y + dt.h / 2, 0x414145);
        if (sample) {
            drawWave(dc, *sample, dt, viewStart, viewLength, 0x77777e);
            int selection = SaveDC(dc); clip(dc, {sx, dt.y, std::max(0.0, ex - sx), dt.h});
            drawWave(dc, *sample, dt, viewStart, viewLength, blue); RestoreDC(dc, selection);
            for (int side = 0; side < 2; ++side) {
                double duration = std::min(plain(side ? FadeOut : FadeIn, model->params[side ? FadeOut : FadeIn].load()) * .001 * sample->rate,
                    std::max(0.0, (finish - start) * sample->frames() - 1) * .5);
                double w = duration / sample->frames() / viewLength * dt.w;
                double edge = side ? ex : sx, inner = side ? ex - w : sx + w;
                line(dc, edge, dt.y + dt.h / 2, inner, dt.y, 0x496c91); line(dc, edge, dt.y + dt.h / 2, inner, dt.y + dt.h, 0x496c91);
            }
        }
        double position = model->playhead.load();
        if (position >= 0) { double x = dt.x + (position - viewStart) / viewLength * dt.w; line(dc, x, dt.y, x, dt.y + dt.h, foreground, 2); }
        for (int side = 0; side < 2; ++side) {
            double x = side ? ex : sx; line(dc, x, dt.y, x, dt.y + dt.h, blue, 2);
            if (x >= dt.x && x <= dt.x + dt.w) { auto tag = loopTag(x, side ? sx : ex, side != 0); box(dc, tag, blue, 6); label(dc, side ? L"E" : L"S", tag, 14, 0xffffff, true, DT_CENTER); }
        }
        RestoreDC(dc, saved);
        line(dc, dt.x, dt.y, dt.x + dt.w, dt.y, 0x55555b);
        for (int i = 0; i <= 32; ++i) {
            double x = dt.x + dt.w * i / 32;
            line(dc, x, dt.y - (i % 4 == 0 ? 9 : 5), x, dt.y, 0x55555b);
            if (i % 4 == 0 && sample) label(dc, format(L"%.3f s", (viewStart + i / 32.0 * viewLength) * sample->frames() / sample->rate),
                {std::clamp(x - 45, dt.x, dt.x + dt.w - 90), 189, 90, 21}, 12, 0xb7b7bf, false, DT_CENTER);
        }
        if (!sample) {
            box(dc, {250, 304, 440, 82}, 0x252528, 12, 0x5d82ac); label(dc, L"Drop a sample here", {270, 319, 400, 28}, 22, foreground, false, DT_CENTER);
            label(dc, L"WAV · AIFF · FLAC", {270, 353, 400, 20}, 13, muted, false, DT_CENTER);
        }
        label(dc, L"Start", {28, 502, 46, 20}, 15, 0xd7d7dc); label(dc, L"End", {196, 502, 38, 20}, 15, 0xd7d7dc); label(dc, L"Length", {356, 502, 58, 20}, 15, 0xd7d7dc);
        label(dc, format(L"%.1f× zoom", 1 / viewLength), {555, 503, 137, 19}, 12, 0x8b8b94, false, DT_RIGHT);
        const wchar_t* zooms[] = {L"−", L"+", L"Fit"}; for (int i = 0; i < 3; ++i) button(dc, zoomButton(i), zooms[i]);
        box(dc, {28, 541, 884, 38}, 0x29292c, 10, 0x36363b); int mode = static_cast<int>(plain(ModeId, model->params[ModeId].load()));
        for (int i = 0; i < 5; ++i) { auto r = modeButton(i); if (i == mode) box(dc, {r.x + 3, r.y + 3, r.w - 6, r.h - 6}, 0x505055, 8);
            label(dc, wide(modeNames[i]), r, 14, i == mode ? 0xf5f5f7 : 0xb6b6bf, i == mode, DT_CENTER); }
        line(dc, 940, 104, 940, 581, 0x444449);
        label(dc, L"Pitch", {968, 115, 180, 29}, 22, foreground, true); label(dc, L"Tune", {968, 161, 110, 23}, 16, 0xe0e0e5);
        pill(dc, valueText(Tune, model->params[Tune].load()), {1144, 155, 108, 32}); drawSlider(dc, sliderRow(0), model->params[Tune].load());
        label(dc, L"Root note", {968, 247, 130, 23}, 16, 0xe0e0e5); button(dc, rootButton(), valueText(Root, model->params[Root].load()) + L" ▾");
        line(dc, 968, 289, 1252, 289, 0x3a3a3f); label(dc, L"Time", {968, 304, 180, 29}, 22, foreground, true);
        auto timing = model->settings(); bool synced = timing.syncLength > 0;
        label(dc, L"Keep duration", {968, 340, 220, 24}, 16, 0xe0e0e5); toggle(dc, speedButton(), synced || timing.keepSpeed);
        label(dc, L"Speed", {968, 390, 110, 23}, 16, 0xe0e0e5);
        double rate = sample ? playbackSpeed(timing, sample->frames(), sample->rate) : timing.speed;
        pill(dc, format(L"%.2f×", rate), {1144, 384, 108, 32}); drawSlider(dc, rateSlider(), model->params[PlaybackRate].load(), !synced);
        button(dc, syncButton(0), L"Free", !synced); button(dc, syncButton(1), L"Sync", synced);
        button(dc, lengthButton(), wide(lengthNames[lastSyncLength]) + L" ▾", false, synced);
        label(dc, model->hostTempoValid.load() ? L"Host tempo" : L"Tempo · BPM", {968, 532, 175, 20}, 13);
        label(dc, synced ? format(L"%d/%d · duration follows the project", model->timeSigNumerator.load(), model->timeSigDenominator.load()) : L"Pitch stays independent of speed", {968, 563, 284, 16}, 11, 0x85858f);
    }
    void draw(HDC dc) {
        box(dc, {0, 0, editorWidth, editorHeight}, 0x1b1b1e, 0);
        auto sample = model->samples.snapshot();
        label(dc, L"Essential Sampler", {28, 30, 260, 37}, 26, foreground, true);
        for (int i = 0; i < 2; ++i) { auto r = tabButton(i); bool active = i == (fxTab ? 1 : 0); if (active) box(dc, r, 0x38383d, 7); label(dc, i ? L"FX" : L"Sampler", r, 13, active ? foreground : 0x92929c, active, DT_CENTER); }
        label(dc, sample ? wide(sample->name) : L"Load your first sample", {300, 32, 650, 30}, 20, foreground, true, DT_CENTER);
        label(dc, sample ? format(L"Stereo  ·  %.0f kHz  ·  %.3f s", sample->rate / 1000, sample->frames() / sample->rate) : L"WAV  ·  AIFF  ·  FLAC", {300, 65, 650, 23}, 14, muted, false, DT_CENTER);
        button(dc, loadButton(), model->loading.load() ? L"Loading…" : L"+  Load sample");
        if (fxTab) drawFx(dc); else drawSampler(dc, sample);
        line(dc, 28, 606, 1252, 606, 0x414146);
        if (!fxTab) {
            label(dc, L"Loop fades", {28, 623, 300, 28}, 21, foreground, true); label(dc, L"Envelope", {420, 623, 300, 28}, 21, foreground, true);
            line(dc, 393, 627, 393, 725, 0x3d3d43); line(dc, 794, 627, 794, 725, 0x3d3d43);
            const wchar_t* titles[] = {L"", L"Fade in", L"Fade out", L"Attack", L"Release"};
            for (int i = 1; i < 5; ++i) { auto r = sliderRow(i); auto id = sliderParams[i];
                label(dc, titles[i], {i < 3 ? 28.0 : 420.0, r.y + 3, 95, 22}, 15, 0xd8d8df); drawSlider(dc, r, model->params[id].load());
                label(dc, format(L"%.0f ms", plain(id, model->params[id].load())), {i < 3 ? 300.0 : 694.0, r.y + 3, 76, 22}, 14, 0xd8d8df, false, DT_RIGHT); }
        } else {
            label(dc, L"Signal flow", {28, 623, 300, 28}, 21, foreground, true);
            const wchar_t* names[] = {L"Sampler", L"Distortion", L"Chorus"};
            for (int i = 0; i < 3; ++i) { button(dc, {28.0 + i * 242, 674, 200, 38}, names[i]); label(dc, L"→", {235.0 + i * 242, 680, 28, 24}, 18, 0x85858f, false, DT_CENTER); }
            line(dc, 794, 627, 794, 725, 0x3d3d43);
        }
        label(dc, L"Output", {820, 623, 300, 28}, 21, foreground, true);
        constexpr double pi = 3.14159265358979323846; double gain = model->params[Gain].load();
        for (int pass = 0; pass < 2; ++pass) {
            double range = pass ? gain : 1; double oldX = 0, oldY = 0;
            for (int i = 0; i <= 80; ++i) { double a = (135 + 270 * range * i / 80) * pi / 180, x = 858 + 29 * std::cos(a), y = 688 + 29 * std::sin(a);
                if (i) line(dc, oldX, oldY, x, y, pass ? blue : 0x515155, 3); oldX = x; oldY = y; }
        }
        box(dc, {835, 665, 46, 46}, 0x343437, 23, 0x55555a); double a = (135 + 270 * gain) * pi / 180;
        line(dc, 858 + 12 * std::cos(a), 688 + 12 * std::sin(a), 858 + 21 * std::cos(a), 688 + 21 * std::sin(a), 0xe7e7e9, 3);
        label(dc, valueText(Gain, gain), {909, 675, 115, 25}, 18, 0xe8e8ed);
        float peak = model->meter.load(); double level = std::clamp((20 * std::log10(std::max(1.e-6f, peak)) + 60) / 60.0, 0.0, 1.0);
        for (int i = 0; i < 20; ++i) box(dc, {1046 + i * 10.3, 675, 7, 18}, i < level * 20 ? (peak > 1 ? 0xff6962 : blue) : 0x3b3b40, 2);
        label(dc, L"−60", {1046, 700, 44, 17}, 10, 0x85858f); label(dc, L"0 dB", {1206, 700, 46, 17}, 10, 0x85858f, false, DT_RIGHT);
        for (int pass = 0; pass < 2; ++pass) for (int n = keyboardBase; n <= keyboardBase + 24; ++n) if (isBlack(n) == (pass != 0)) {
            auto r = keyRect(n, keyboardBase); box(dc, r, held[n] ? 0x2865a5 : pass ? 0x111113 : 0x45454a, pass ? 4 : 5, pass ? 0x08080a : 0x242428);
            if (n % 12 == 0) label(dc, format(L"C%d", n / 12 - 1), {r.x + 6, r.y + r.h - 23, r.w - 12, 20}, 13, 0xdddde3);
        }
        for (int i = 0; i < 2; ++i) button(dc, octaveButton(i), i ? L"+" : L"−");
        label(dc, L"Octave", {28, 756, 88, 18}, 11, 0x85858f, false, DT_CENTER); line(dc, 1115, 764, 1115, 818, 0x444449);
        label(dc, format(L"%d / 16 voices", model->activeVoices.load()), {1134, 784, 118, 22}, 14, muted, false, DT_CENTER);
        auto status = model->getStatus(); label(dc, status.empty() ? L"Essential Sampler  ·  0.7.0" : wide(status), {28, 840, 1180, 16}, 10, status.empty() ? 0x65656f : 0xffb58a);
    }
    void paint(HDC dc) {
        HDC buffer = CreateCompatibleDC(dc); HBITMAP bitmap = CreateCompatibleBitmap(dc, editorWidth, editorHeight);
        if (!buffer || !bitmap) { if (buffer) DeleteDC(buffer); if (bitmap) DeleteObject(bitmap); draw(dc); return; }
        auto old = SelectObject(buffer, bitmap); draw(buffer); BitBlt(dc, 0, 0, editorWidth, editorHeight, buffer, 0, 0, SRCCOPY);
        SelectObject(buffer, old); DeleteObject(bitmap); DeleteDC(buffer);
    }
    LRESULT message(UINT msg, WPARAM w, LPARAM l) {
        switch (msg) {
            case WM_ERASEBKGND: return 1;
            case WM_PAINT: { PAINTSTRUCT ps{}; HDC dc = BeginPaint(window, &ps); paint(dc); EndPaint(window, &ps); return 0; }
            case WM_PRINTCLIENT: paint(reinterpret_cast<HDC>(w)); return 0;
            case WM_TIMER:
                if (w == refreshTimer) {
                    completeLoad(); refreshFields();
                    HWND active = GetForegroundWindow();
                    if (active != GetAncestor(window, GA_ROOT) && (drag || mouseNote >= 0 || std::any_of(held.begin(), held.end(), [](bool v) { return v; }))) { finishGesture(); stopNotes(); }
                    invalidate();
                }
                return 0;
            case WM_CTLCOLOREDIT: case WM_CTLCOLORSTATIC:
                SetTextColor(reinterpret_cast<HDC>(w), colour(foreground)); SetBkColor(reinterpret_cast<HDC>(w), colour(0x29292c)); return reinterpret_cast<LRESULT>(fieldBrush);
            case WM_COMMAND:
                if (HIWORD(w) == EN_KILLFOCUS && LOWORD(w) >= 100 && LOWORD(w) < 104 && !detached) {
                    HWND field = reinterpret_cast<HWND>(l);
                    if (skipKillFocus == field) skipKillFocus = nullptr;
                    else commitField(field);
                }
                return 0;
            case WM_MOUSEACTIVATE: return hosted ? MA_NOACTIVATE : MA_ACTIVATE;
            case WM_LBUTTONDOWN: case WM_LBUTTONDBLCLK: mouseDown({GET_X_LPARAM(l), GET_Y_LPARAM(l)}, msg == WM_LBUTTONDBLCLK); return 0;
            case WM_MOUSEMOVE: mouseMove({GET_X_LPARAM(l), GET_Y_LPARAM(l)}); return 0;
            case WM_LBUTTONUP: finishGesture(); invalidate(); return 0;
            case WM_CAPTURECHANGED: if (reinterpret_cast<HWND>(l) != window) { finishGesture(); invalidate(); } return 0;
            case WM_CANCELMODE: finishGesture(); stopNotes(); return 0;
            case WM_KILLFOCUS: finishGesture(); stopNotes(); return 0;
            case WM_ACTIVATEAPP: if (!w) { finishGesture(); stopNotes(); } break;
            case WM_SHOWWINDOW: if (!w) { finishGesture(); stopNotes(); } break;
            case WM_GETDLGCODE: return 0;
            case WM_KEYDOWN: case WM_SYSKEYDOWN:
                if (keyDown(w, l)) return 0;
                if (hosted && GetParent(window)) return SendMessageW(GetParent(window), msg, w, l);
                break;
            case WM_KEYUP: case WM_SYSKEYUP:
                if (keyUp(w)) return 0;
                if (hosted && GetParent(window)) return SendMessageW(GetParent(window), msg, w, l);
                break;
            case WM_CHAR: case WM_SYSCHAR:
                if (hosted && GetParent(window)) return SendMessageW(GetParent(window), msg, w, l);
                break;
            case WM_MOUSEWHEEL: case WM_MOUSEHWHEEL: {
                POINT p{GET_X_LPARAM(l), GET_Y_LPARAM(l)}; ScreenToClient(window, &p);
                if (fxTab || (!detail().contains(p) && !overview().contains(p))) break;
                double steps = GET_WHEEL_DELTA_WPARAM(w) / static_cast<double>(WHEEL_DELTA);
                if (msg == WM_MOUSEHWHEEL || (GET_KEYSTATE_WPARAM(w) & MK_SHIFT)) viewStart = std::clamp(viewStart - steps * .08 * viewLength, 0.0, 1 - viewLength);
                else zoom(std::exp(steps * .24), p.x);
                invalidate(); return 0;
            }
            case WM_GESTURE: {
                GESTUREINFO info{}; info.cbSize = sizeof(info);
                if (!GetGestureInfo(reinterpret_cast<HGESTUREINFO>(l), &info)) break;
                POINT p{info.ptsLocation.x, info.ptsLocation.y}; ScreenToClient(window, &p);
                bool relevant = !fxTab && (detail().contains(p) || overview().contains(p));
                if (relevant && info.dwID == GID_ZOOM) {
                    if (!(info.dwFlags & GF_BEGIN) && gestureDistance && info.ullArguments) zoom(static_cast<double>(info.ullArguments) / gestureDistance, p.x);
                    gestureDistance = info.ullArguments;
                } else if (relevant && info.dwID == GID_PAN) {
                    if (!(info.dwFlags & GF_BEGIN)) viewStart = std::clamp(viewStart - (p.x - gesturePosition.x) / detail().w * viewLength, 0.0, 1 - viewLength);
                    gesturePosition = p; invalidate();
                } else break; // DefWindowProc owns and closes unhandled gestures.
                CloseGestureInfoHandle(reinterpret_cast<HGESTUREINFO>(l)); return 0;
            }
            case WM_DROPFILES: {
                HDROP drop = reinterpret_cast<HDROP>(w); UINT length = DragQueryFileW(drop, 0, nullptr, 0);
                std::wstring path(static_cast<size_t>(length) + 1, L'\0');
                if (length && DragQueryFileW(drop, 0, path.data(), length + 1)) { path.resize(length); loadPath(path); }
                DragFinish(drop); return 0;
            }
            case WM_DESTROY:
                finishGesture(); stopNotes(); detached = true; KillTimer(window, refreshTimer); return 0;
        }
        return DefWindowProcW(window, msg, w, l);
    }
    static LRESULT CALLBACK windowProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
        Impl* self = reinterpret_cast<Impl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
        if (msg == WM_NCCREATE) {
            self = static_cast<Impl*>(reinterpret_cast<CREATESTRUCTW*>(l)->lpCreateParams);
            self->window = hwnd; SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        if (!self) return DefWindowProcW(hwnd, msg, w, l);
        LRESULT result = self->message(msg, w, l);
        if (msg == WM_NCDESTROY) { SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0); self->window = nullptr; self->fields.fill(nullptr); }
        return result;
    }
};

WindowsEditor::WindowsEditor(std::shared_ptr<Model> model, bool hosted) : impl(std::make_unique<Impl>(std::move(model), hosted)) {}
WindowsEditor::~WindowsEditor() = default;
bool WindowsEditor::attach(void* parent) { return impl->attach(static_cast<HWND>(parent)); }
void WindowsEditor::detach() { impl->detach(); }
void WindowsEditor::stopNotes() { impl->stopNotes(); }
void WindowsEditor::setCallbacks(std::function<void(uint32_t)> begin, std::function<void(uint32_t, double)> change,
    std::function<void(uint32_t)> end, std::function<void()> dirty) {
    impl->begin = std::move(begin); impl->change = std::move(change); impl->end = std::move(end); impl->dirty = std::move(dirty);
}
void* WindowsEditor::nativeHandle() const { return impl->window; }
void WindowsEditor::loadPath(const std::wstring& path) { impl->loadPath(path); }
} // namespace hasio
