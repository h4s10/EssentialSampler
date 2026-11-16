#include "Engine.hpp"
#include "State.hpp"
#include "Editor.hpp"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#include <cstdio>
#include <cstdlib>

using namespace Steinberg;
using namespace Steinberg::Vst;
using namespace hasio;
namespace {
DECLARE_UID(componentId, 0x48415349, 0x4F4C4F4F, 0x50565354, 0x33000001)
bool same(const char* a, const char* b) { return a && b && std::memcmp(a, b, 16) == 0; }
template<size_t N> void ascii(char (&out)[N], const char* s) { std::snprintf(out, N, "%s", s); }
void text16(TChar* out, const char* s, size_t capacity = 128) {
    size_t i = 0; while (s[i] && i + 1 < capacity) { out[i] = static_cast<unsigned char>(s[i]); ++i; } out[i] = 0;
}
bool transfer(IBStream* stream, void* bytes, size_t size, bool write) {
    auto* p = static_cast<uint8_t*>(bytes);
    while (size) {
        int32 done = 0, count = static_cast<int32>(std::min<size_t>(size, 1 << 20));
        auto result = write ? stream->write(p, count, &done) : stream->read(p, count, &done);
        if (done <= 0 || done > count) return false;
        p += done; size -= done;
        if (result != kResultOk && size) return false;
    }
    return true;
}
class Plugin;
class Editor final : public IPlugView {
    std::atomic<uint32> refs{1};
    Plugin* owner;
    HLView* __strong view = nil;
    IPlugFrame* frame = nullptr;
public:
    explicit Editor(Plugin* p);
    ~Editor();
    tresult PLUGIN_API queryInterface(const TUID iid, void** out) override {
        if (!out) return kInvalidArgument; *out = nullptr;
        if (!same(iid, FUnknown_iid) && !same(iid, IPlugView_iid)) return kNoInterface;
        *out = static_cast<IPlugView*>(this); addRef(); return kResultOk;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    tresult PLUGIN_API isPlatformTypeSupported(FIDString type) override { return type && !std::strcmp(type, kPlatformTypeNSView) ? kResultTrue : kResultFalse; }
    tresult PLUGIN_API attached(void* parent, FIDString type) override;
    tresult PLUGIN_API removed() override { if (view) { [view detach]; [view removeFromSuperview]; view = nil; } return kResultOk; }
    tresult PLUGIN_API onWheel(float) override { return kResultFalse; }
    tresult PLUGIN_API onKeyDown(char16, int16, int16) override { return kResultFalse; }
    tresult PLUGIN_API onKeyUp(char16, int16, int16) override { return kResultFalse; }
    tresult PLUGIN_API getSize(ViewRect* r) override { if (!r) return kInvalidArgument; *r = ViewRect(0, 0, editorWidth, editorHeight); return kResultOk; }
    tresult PLUGIN_API onSize(ViewRect* r) override { return r && r->getWidth() == editorWidth && r->getHeight() == editorHeight ? kResultOk : kResultFalse; }
    tresult PLUGIN_API onFocus(TBool state) override { if (!state) [view stopNotes]; return kResultOk; }
    tresult PLUGIN_API setFrame(IPlugFrame* f) override { if (f) f->addRef(); if (frame) frame->release(); frame = f; return kResultOk; }
    tresult PLUGIN_API canResize() override { return kResultFalse; }
    tresult PLUGIN_API checkSizeConstraint(ViewRect* r) override { if (!r) return kInvalidArgument; r->right = r->left + editorWidth; r->bottom = r->top + editorHeight; return kResultOk; }
};

// A VST3 single-component instrument. Hosts query IEditController on the same
// object; getControllerClassId intentionally returns kResultFalse.
class Plugin final : public IComponent, public IAudioProcessor, public IEditController, public IProcessContextRequirements {
    std::atomic<uint32> refs{1};
    bool initialized = false, audioBusActive = true, eventBusActive = true;
    Engine engine;
    double rate = 48000;
    IComponentHandler* handler = nullptr;
public:
    std::shared_ptr<Model> model = std::make_shared<Model>();
    ~Plugin() { if (handler) handler->release(); }
    tresult PLUGIN_API queryInterface(const TUID iid, void** out) override {
        if (!out) return kInvalidArgument; *out = nullptr;
        if (same(iid, FUnknown_iid) || same(iid, IPluginBase_iid) || same(iid, IComponent_iid)) *out = static_cast<IComponent*>(this);
        else if (same(iid, IAudioProcessor_iid)) *out = static_cast<IAudioProcessor*>(this);
        else if (same(iid, IEditController_iid)) *out = static_cast<IEditController*>(this);
        else if (same(iid, IProcessContextRequirements_iid)) *out = static_cast<IProcessContextRequirements*>(this);
        if (!*out) return kNoInterface; addRef(); return kResultOk;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    tresult PLUGIN_API initialize(FUnknown*) override { if (initialized) return kResultFalse; initialized = true; return kResultOk; }
    tresult PLUGIN_API terminate() override { engine.allNotesOff(); initialized = false; setComponentHandler(nullptr); return kResultOk; }
    tresult PLUGIN_API getControllerClassId(TUID) override { return kResultFalse; }
    tresult PLUGIN_API setIoMode(IoMode) override { return kResultOk; }
    int32 PLUGIN_API getBusCount(MediaType type, BusDirection dir) override {
        return (type == kAudio && dir == kOutput) || (type == kEvent && dir == kInput) ? 1 : 0;
    }
    tresult PLUGIN_API getBusInfo(MediaType type, BusDirection dir, int32 index, BusInfo& info) override {
        if (index != 0 || getBusCount(type, dir) != 1) return kInvalidArgument;
        info = {}; info.mediaType = type; info.direction = dir; info.busType = kMain; info.flags = BusInfo::kDefaultActive;
        info.channelCount = type == kAudio ? 2 : 16; text16(info.name, type == kAudio ? "Stereo output" : "MIDI input"); return kResultOk;
    }
    tresult PLUGIN_API getRoutingInfo(RoutingInfo&, RoutingInfo&) override { return kNotImplemented; }
    tresult PLUGIN_API activateBus(MediaType type, BusDirection dir, int32 index, TBool active) override {
        if (index || !getBusCount(type, dir)) return kInvalidArgument;
        if (type == kAudio) audioBusActive = active; else eventBusActive = active; return kResultOk;
    }
    tresult PLUGIN_API setActive(TBool state) override { if (!state) { engine.allNotesOff(); model->playhead.store(-1); model->activeVoices.store(0); } return kResultOk; }
    tresult PLUGIN_API setState(IBStream* stream) override {
        if (!stream) return kInvalidArgument;
        try {
            uint64_t size = 0;
            if (!transfer(stream, &size, sizeof(size), false) || size > maxSampleBytes + 8192 || size < 100) return kResultFalse;
            std::vector<uint8_t> bytes(size);
            return transfer(stream, bytes.data(), bytes.size(), false) && hasio::loadState(*model, bytes.data(), bytes.size()) ? kResultOk : kResultFalse;
        } catch (...) { return kOutOfMemory; }
    }
    tresult PLUGIN_API getState(IBStream* stream) override {
        if (!stream) return kInvalidArgument;
        try {
            auto bytes = hasio::saveState(*model); uint64_t size = bytes.size();
            return transfer(stream, &size, sizeof(size), true) && transfer(stream, bytes.data(), bytes.size(), true) ? kResultOk : kResultFalse;
        } catch (...) { return kOutOfMemory; }
    }
    tresult PLUGIN_API setComponentState(IBStream* stream) override { return setState(stream); }
    tresult PLUGIN_API setBusArrangements(SpeakerArrangement*, int32 ins, SpeakerArrangement* outs, int32 numOuts) override {
        return ins == 0 && numOuts == 1 && outs && outs[0] == SpeakerArr::kStereo ? kResultTrue : kResultFalse;
    }
    tresult PLUGIN_API getBusArrangement(BusDirection dir, int32 index, SpeakerArrangement& arr) override {
        if (dir != kOutput || index != 0) return kInvalidArgument; arr = SpeakerArr::kStereo; return kResultOk;
    }
    tresult PLUGIN_API canProcessSampleSize(int32 size) override { return size == kSample32 || size == kSample64 ? kResultTrue : kResultFalse; }
    uint32 PLUGIN_API getLatencySamples() override { return Engine::latencySamples(); }
    uint32 PLUGIN_API getProcessContextRequirements() override { return kNeedTempo | kNeedTimeSignature; }
    tresult PLUGIN_API setupProcessing(ProcessSetup& setup) override {
        if (!std::isfinite(setup.sampleRate) || setup.sampleRate < 8000 || setup.sampleRate > 384000 || setup.maxSamplesPerBlock <= 0 || canProcessSampleSize(setup.symbolicSampleSize) != kResultTrue) return kInvalidArgument;
        rate = setup.sampleRate; engine.prepare(rate); return kResultOk;
    }
    tresult PLUGIN_API setProcessing(TBool state) override { if (!state) { engine.allNotesOff(); model->playhead.store(-1); model->activeVoices.store(0); model->meter.store(0); } return kResultOk; }
    uint32 PLUGIN_API getTailSamples() override { return kInfiniteTail; }
    tresult PLUGIN_API process(ProcessData& data) override {
        if (data.numSamples < 0 || canProcessSampleSize(data.symbolicSampleSize) != kResultTrue) return kInvalidArgument;
        const auto* context = data.processContext;
        const bool tempoValid = context && (context->state & ProcessContext::kTempoValid);
        const bool meterValid = context && (context->state & ProcessContext::kTimeSigValid);
        model->setHostTiming(tempoValid ? context->tempo : 0, meterValid ? context->timeSigNumerator : 4, meterValid ? context->timeSigDenominator : 4);
        engine.setSample(model->samples.pin()); engine.configure(model->settings());
        if (model->panic.exchange(false)) engine.allNotesOff();
        Note note; while (model->notes.pop(note)) engine.previewEvent(note);
        struct Cursor { IParamValueQueue* queue = nullptr; int32 index = 0, count = 0, offset = 0; double value = 0; };
        std::array<Cursor, ParamCount> cursors{};
        if (data.inputParameterChanges) for (int q = 0; q < data.inputParameterChanges->getParameterCount(); ++q) {
            auto* queue = data.inputParameterChanges->getParameterData(q);
            if (!queue || queue->getParameterId() >= ParamCount || queue->getPointCount() <= 0) continue;
            auto& c = cursors[queue->getParameterId()]; c.queue = queue; c.count = queue->getPointCount();
            if (data.numSamples == 0) { int32 offset; double v; if (queue->getPoint(c.count - 1, offset, v) == kResultOk) model->params[queue->getParameterId()].store(norm(v)); }
            else if (queue->getPoint(0, c.offset, c.value) != kResultOk) c.queue = nullptr;
        }
        auto* events = eventBusActive ? data.inputEvents : nullptr;
        const int eventCount = events ? events->getEventCount() : 0; int eventIndex = 0;
        Event event{}; bool hasEvent = eventIndex < eventCount && events->getEvent(eventIndex, event) == kResultOk;
        AudioBusBuffers* out = data.numOutputs > 0 && data.outputs ? &data.outputs[0] : nullptr;
        float peak = 0;
        for (int i = 0; i < data.numSamples; ++i) {
            bool changed = false;
            for (uint32_t p = 0; p < ParamCount; ++p) {
                auto& c = cursors[p];
                while (c.queue && c.offset <= i) {
                    model->params[p].store(norm(c.value)); changed = true;
                    if (++c.index >= c.count || c.queue->getPoint(c.index, c.offset, c.value) != kResultOk) c.queue = nullptr;
                }
            }
            if (changed) engine.configure(model->settings());
            while (hasEvent && event.sampleOffset <= i) {
                if (event.busIndex == 0) {
                    if (event.type == Event::kNoteOnEvent) engine.noteOn(event.noteOn.pitch, event.noteOn.velocity, event.noteOn.noteId, event.noteOn.channel);
                    else if (event.type == Event::kNoteOffEvent) engine.noteOff(event.noteOff.pitch, event.noteOff.noteId, event.noteOff.channel);
                }
                hasEvent = ++eventIndex < eventCount && events->getEvent(eventIndex, event) == kResultOk;
            }
            float l, r; engine.render(l, r); if (!audioBusActive) l = r = 0;
            peak = std::max({peak, std::abs(l), std::abs(r)});
            if (out) for (int ch = 0; ch < out->numChannels; ++ch) {
                float value = ch == 0 ? l : ch == 1 ? r : 0;
                if (data.symbolicSampleSize == kSample32) { if (out->channelBuffers32 && out->channelBuffers32[ch]) out->channelBuffers32[ch][i] = value; }
                else if (out->channelBuffers64 && out->channelBuffers64[ch]) out->channelBuffers64[ch][i] = value;
            }
        }
        if (out) out->silenceFlags = peak > 0 ? 0 : (out->numChannels >= 64 ? ~uint64_t(0) : (uint64_t(1) << out->numChannels) - 1);
        model->playhead.store(engine.playhead()); model->activeVoices.store(engine.activeCount());
        model->meter.store(std::max(peak, model->meter.load() * .92f)); model->samples.unpin(); return kResultOk;
    }
    int32 PLUGIN_API getParameterCount() override { return ParamCount; }
    tresult PLUGIN_API getParameterInfo(int32 index, ParameterInfo& info) override {
        if (index < 0 || index >= static_cast<int32>(ParamCount)) return kInvalidArgument;
        info = {}; info.id = index; text16(info.title, paramNames[index]); text16(info.shortTitle, paramNames[index]);
        info.defaultNormalizedValue = defaults[index]; info.unitId = 0; info.flags = ParameterInfo::kCanAutomate;
        info.stepCount = index == ModeId ? 4 : index == Root ? 127 : (index == KeepSpeed || index == DistEnabled || index == ChorusEnabled) ? 1 : index == DistType ? 5 : index == SyncLength ? lengthCount - 1 : 0;
        if (index == LegacyCrossfade) info.flags = ParameterInfo::kIsHidden | ParameterInfo::kIsReadOnly;
        if (index == ModeId || index == SyncLength || index == DistType) info.flags |= ParameterInfo::kIsList;
        const char* unit = index == ChorusRate ? "Hz" : index == ChorusDelay ? "ms" : (index >= static_cast<int32>(DistAmount) && index != ChorusEnabled) ? "%" : index == Gain ? "dB" : index == Tune ? "st" : index == Root ? "MIDI" : index == PlaybackRate ? "x" : index == Tempo ? "BPM" : index >= static_cast<int32>(Attack) && index <= static_cast<int32>(FadeOut) ? "ms" : "";
        text16(info.units, unit); return kResultOk;
    }
    tresult PLUGIN_API getParamStringByValue(ParamID id, ParamValue value, String128 out) override {
        if (id >= ParamCount) return kInvalidArgument;
        if (id == ModeId) text16(out, modeNames[static_cast<int>(plain(id, value))]);
        else if (id == DistType) text16(out, distortionNames[static_cast<int>(plain(id, value))]);
        else if (id == KeepSpeed || id == DistEnabled || id == ChorusEnabled) text16(out, plain(id, value) > .5 ? "On" : "Off");
        else if (id == SyncLength) text16(out, lengthNames[static_cast<int>(plain(id, value))]);
        else { char buffer[80]; std::snprintf(buffer, sizeof(buffer), id == Root ? "%.0f" : id == Start || id == End ? "%.6f" : "%.2f", plain(id, value)); text16(out, buffer); }
        return kResultOk;
    }
    tresult PLUGIN_API getParamValueByString(ParamID id, TChar* text, ParamValue& value) override {
        if (id >= ParamCount || !text) return kInvalidArgument;
        char s[128]{}; for (int i = 0; i < 127 && text[i]; ++i) s[i] = static_cast<char>(text[i]);
        if (id == DistType) for (int i = 0; i < 6; ++i) if (!std::strcmp(s, distortionNames[i])) { value = normalized(DistType, i); return kResultOk; }
        if (id == ModeId) for (int i = 0; i < 5; ++i) if (!std::strcmp(s, modeNames[i])) { value = i / 4.0; return kResultOk; }
        if ((id == KeepSpeed || id == DistEnabled || id == ChorusEnabled) && (!std::strcmp(s, "On") || !std::strcmp(s, "Off"))) { value = !std::strcmp(s, "On") ? 1 : 0; return kResultOk; }
        if (id == SyncLength) for (int i = 0; i < lengthCount; ++i) if (!std::strcmp(s, lengthNames[i])) { value = normalized(SyncLength, i); return kResultOk; }
        char* end = nullptr; double v = std::strtod(s, &end); if (end == s || !std::isfinite(v)) return kResultFalse;
        value = normalized(id, v); return kResultOk;
    }
    ParamValue PLUGIN_API normalizedParamToPlain(ParamID id, ParamValue v) override { return id < ParamCount ? plain(id, v) : 0; }
    ParamValue PLUGIN_API plainParamToNormalized(ParamID id, ParamValue v) override { return id < ParamCount ? normalized(id, v) : 0; }
    ParamValue PLUGIN_API getParamNormalized(ParamID id) override { return id < ParamCount ? model->params[id].load() : 0; }
    tresult PLUGIN_API setParamNormalized(ParamID id, ParamValue v) override { if (id >= ParamCount) return kInvalidArgument; model->params[id].store(norm(v)); return kResultOk; }
    tresult PLUGIN_API setComponentHandler(IComponentHandler* h) override { if (h) h->addRef(); if (handler) handler->release(); handler = h; return kResultOk; }
    IPlugView* PLUGIN_API createView(FIDString name) override { return name && !std::strcmp(name, ViewType::kEditor) ? new Editor(this) : nullptr; }
    void beginEdit(uint32_t p) { if (handler) handler->beginEdit(p); }
    void change(uint32_t p, double v) { if (handler) handler->performEdit(p, v); }
    void endEdit(uint32_t p) { if (handler) handler->endEdit(p); }
    void dirty() {
        if (!handler) return; IComponentHandler2* h = nullptr;
        if (handler->queryInterface(IComponentHandler2_iid, reinterpret_cast<void**>(&h)) == kResultOk && h) { h->setDirty(true); h->release(); }
    }
};
Editor::Editor(Plugin* p) : owner(p) { owner->addRef(); }
Editor::~Editor() { removed(); if (frame) frame->release(); owner->release(); }
tresult Editor::attached(void* parent, FIDString type) {
    if (!parent || view || isPlatformTypeSupported(type) != kResultTrue) return kInvalidArgument;
    view = [[HLView alloc] initWithModel:owner->model]; [view setHosted:YES]; auto* p = owner;
    [view setBeginEdit:[p](uint32_t id) { p->beginEdit(id); }
               change:[p](uint32_t id, double v) { p->change(id, v); }
                  end:[p](uint32_t id) { p->endEdit(id); }
                dirty:[p]() { p->dirty(); }];
    [(__bridge NSView*)parent addSubview:view]; return kResultOk;
}
class Factory final : public IPluginFactory2 {
    std::atomic<uint32> refs{1};
public:
    tresult PLUGIN_API queryInterface(const TUID iid, void** out) override {
        if (!out) return kInvalidArgument; *out = nullptr;
        if (!same(iid, FUnknown_iid) && !same(iid, IPluginFactory_iid) && !same(iid, IPluginFactory2_iid)) return kNoInterface;
        *out = static_cast<IPluginFactory2*>(this); addRef(); return kResultOk;
    }
    uint32 PLUGIN_API addRef() override { return ++refs; }
    uint32 PLUGIN_API release() override { auto n = --refs; if (!n) delete this; return n; }
    int32 PLUGIN_API countClasses() override { return 1; }
    tresult PLUGIN_API getFactoryInfo(PFactoryInfo* info) override {
        if (!info) return kInvalidArgument; *info = {}; ascii(info->vendor, "hasio"); info->flags = PFactoryInfo::kUnicode; return kResultOk;
    }
    tresult PLUGIN_API getClassInfo(int32 index, PClassInfo* info) override {
        if (index || !info) return kInvalidArgument; *info = {}; std::memcpy(info->cid, componentId, 16);
        info->cardinality = PClassInfo::kManyInstances; ascii(info->category, kVstAudioEffectClass); ascii(info->name, "Hasio Loop"); return kResultOk;
    }
    tresult PLUGIN_API getClassInfo2(int32 index, PClassInfo2* info) override {
        if (index || !info) return kInvalidArgument; *info = {}; std::memcpy(info->cid, componentId, 16);
        info->cardinality = PClassInfo::kManyInstances; ascii(info->category, kVstAudioEffectClass); ascii(info->name, "Hasio Loop");
        ascii(info->subCategories, "Instrument|Sampler"); ascii(info->vendor, "hasio"); ascii(info->version, "0.6.1"); ascii(info->sdkVersion, "VST 3.8.0"); return kResultOk;
    }
    tresult PLUGIN_API createInstance(FIDString cid, FIDString iid, void** out) override {
        if (!out) return kInvalidArgument; *out = nullptr; if (!same(cid, componentId)) return kNoInterface;
        try { auto* p = new Plugin; auto result = p->queryInterface(iid, out); p->release(); return result; } catch (...) { return kOutOfMemory; }
    }
};
}
extern "C" __attribute__((visibility("default"))) bool bundleEntry(CFBundleRef) { return true; }
extern "C" __attribute__((visibility("default"))) bool bundleExit() { return true; }
extern "C" __attribute__((visibility("default"))) IPluginFactory* GetPluginFactory() { return new Factory; }
