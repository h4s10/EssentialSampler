#pragma once
#include "Editor.hpp"
#include <memory>
#include <string>

namespace hasio {
// A fixed-size, native child window. All methods, including destruction, belong
// to the owning UI thread; only the decoder job runs in the background.
class WindowsEditor {
public:
    WindowsEditor(std::shared_ptr<Model> model, bool hosted);
    ~WindowsEditor();
    WindowsEditor(const WindowsEditor&) = delete;
    WindowsEditor& operator=(const WindowsEditor&) = delete;
    bool attach(void* parent);
    void detach();
    void stopNotes();
    void setCallbacks(std::function<void(uint32_t)> begin,
                      std::function<void(uint32_t, double)> change,
                      std::function<void(uint32_t)> end,
                      std::function<void()> dirty);
    void* nativeHandle() const;
    void loadPath(const std::wstring& path);
private:
    struct Impl;
    std::unique_ptr<Impl> impl;
};
} // namespace hasio
