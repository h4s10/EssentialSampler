#include "Engine.hpp"
#include "State.hpp"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstprocesscontext.h"
#ifdef _WIN32
#include <windows.h>
#else
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#endif
#include <cassert>
#include <iostream>
using namespace Steinberg;
using namespace Steinberg::Vst;
struct Stream final : IBStream {
    std::vector<uint8_t> bytes; size_t pos = 0;
    tresult PLUGIN_API queryInterface(const TUID, void** out) override { *out = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API read(void* data, int32 n, int32* done) override {
        size_t size = std::min<size_t>(n, bytes.size() - pos); std::memcpy(data, bytes.data() + pos, size); pos += size;
        if (done) *done = static_cast<int32>(size); return size == static_cast<size_t>(n) ? kResultOk : kResultFalse;
    }
    tresult PLUGIN_API write(void* data, int32 n, int32* done) override {
        bytes.resize(std::max(bytes.size(), pos + n)); std::memcpy(bytes.data() + pos, data, n); pos += n; if (done) *done = n; return kResultOk;
    }
    tresult PLUGIN_API seek(int64 p, int32 mode, int64* result) override {
        int64 next = p + (mode == kIBSeekCur ? pos : mode == kIBSeekEnd ? bytes.size() : 0);
        if (next < 0 || static_cast<size_t>(next) > bytes.size()) return kInvalidArgument; pos = next; if (result) *result = pos; return kResultOk;
    }
    tresult PLUGIN_API tell(int64* p) override { if (!p) return kInvalidArgument; *p = pos; return kResultOk; }
};
struct Events final : IEventList {
    std::vector<Event> list;
    tresult PLUGIN_API queryInterface(const TUID, void** out) override { *out = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getEventCount() override { return static_cast<int32>(list.size()); }
    tresult PLUGIN_API getEvent(int32 i, Event& e) override { if (i < 0 || i >= getEventCount()) return kInvalidArgument; e = list[i]; return kResultOk; }
    tresult PLUGIN_API addEvent(Event& e) override { list.push_back(e); return kResultOk; }
};
struct Queue final : IParamValueQueue {
    ParamID id = hasio::ModeId;
    std::vector<std::pair<int32, double>> points;
    tresult PLUGIN_API queryInterface(const TUID, void** out) override { *out = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return static_cast<int32>(points.size()); }
    tresult PLUGIN_API getPoint(int32 i, int32& offset, ParamValue& value) override {
        if (i < 0 || i >= getPointCount()) return kInvalidArgument; offset = points[i].first; value = points[i].second; return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32 offset, ParamValue value, int32& i) override { i = getPointCount(); points.emplace_back(offset, value); return kResultOk; }
};
struct Changes final : IParameterChanges {
    Queue queue;
    tresult PLUGIN_API queryInterface(const TUID, void** out) override { *out = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getParameterCount() override { return 1; }
    IParamValueQueue* PLUGIN_API getParameterData(int32 index) override { return index == 0 ? &queue : nullptr; }
    IParamValueQueue* PLUGIN_API addParameterData(const ParamID& id, int32& index) override { queue.id = id; index = 0; return &queue; }
};
#ifndef _WIN32
@interface HostEditorSurface : NSView
@property(nonatomic) int backspaces;
@end
@implementation HostEditorSurface
- (BOOL)acceptsFirstResponder { return YES; }
- (void)keyDown:(NSEvent*)event { if (event.keyCode == 51) ++_backspaces; }
@end

#else
static int hostBackspaces = 0;
static LRESULT CALLBACK hostWindowProc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_KEYDOWN && w == VK_BACK) { ++hostBackspaces; return 0; }
    return DefWindowProcW(hwnd, msg, w, l);
}
#endif
int main(int argc, char** argv) {
    assert(argc == 2);
#ifdef _WIN32
    {
        auto handle = LoadLibraryA(argv[1]);
        if (!handle) { std::cerr << "LoadLibrary error " << GetLastError() << '\n'; return 1; }
        auto entry = reinterpret_cast<bool (*)()>(GetProcAddress(handle, "InitDll"));
        auto exit = reinterpret_cast<bool (*)()>(GetProcAddress(handle, "ExitDll"));
        assert(entry && exit && entry());
        auto getFactory = reinterpret_cast<IPluginFactory* (*)()>(GetProcAddress(handle, "GetPluginFactory")); assert(getFactory);
#else
    @autoreleasepool {
        [NSApplication sharedApplication];
        auto handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL); if (!handle) { std::cerr << dlerror() << '\n'; return 1; }
        auto entry = reinterpret_cast<bool (*)(CFBundleRef)>(dlsym(handle, "bundleEntry"));
        auto exit = reinterpret_cast<bool (*)()>(dlsym(handle, "bundleExit"));
        assert(entry && exit && entry(nullptr));
        auto getFactory = reinterpret_cast<IPluginFactory* (*)()>(dlsym(handle, "GetPluginFactory")); assert(getFactory);
#endif
        auto factory = getFactory(); assert(factory && factory->countClasses() == 1);
        PClassInfo info{}; assert(factory->getClassInfo(0, &info) == kResultOk);
        assert(std::string(info.name) == "Essential Sampler");
        DECLARE_UID(expectedId, 0x48415349, 0x4F4C4F4F, 0x50565354, 0x33000001)
        assert(std::memcmp(info.cid, expectedId, 16) == 0);
        IPluginFactory2* f2 = nullptr; assert(factory->queryInterface(IPluginFactory2_iid, reinterpret_cast<void**>(&f2)) == kResultOk);
        PClassInfo2 info2{}; assert(f2->getClassInfo2(0, &info2) == kResultOk); assert(std::string(info2.subCategories) == "Instrument|Sampler"); assert(std::string(info2.version) == "0.7.0"); f2->release();
        IComponent* comp = nullptr;
        assert(factory->createInstance(info.cid, IComponent_iid, reinterpret_cast<void**>(&comp)) == kResultOk);
        assert(comp->initialize(nullptr) == kResultOk);
        IAudioProcessor* processor = nullptr; IEditController* control = nullptr;
        assert(comp->queryInterface(IAudioProcessor_iid, reinterpret_cast<void**>(&processor)) == kResultOk);
        assert(comp->queryInterface(IEditController_iid, reinterpret_cast<void**>(&control)) == kResultOk);
        IProcessContextRequirements* timing = nullptr;
        assert(comp->queryInterface(IProcessContextRequirements_iid, reinterpret_cast<void**>(&timing)) == kResultOk);
        assert(timing->getProcessContextRequirements() == (IProcessContextRequirements::kNeedTempo | IProcessContextRequirements::kNeedTimeSignature)); timing->release();
        assert(control->getParameterCount() == hasio::ParamCount);
        BusInfo bus{}; assert(comp->getBusInfo(kAudio, kOutput, 0, bus) == kResultOk && bus.channelCount == 2);
        assert(comp->getBusCount(kAudio, kInput) == 0 && comp->getBusCount(kEvent, kInput) == 1);
        SpeakerArrangement output = SpeakerArr::kStereo;
        assert(processor->setBusArrangements(nullptr, 0, &output, 1) == kResultTrue);
        for (int i = 0; i < hasio::ParamCount; ++i) { ParameterInfo p{}; assert(control->getParameterInfo(i, p) == kResultOk); assert(p.id == static_cast<uint32>(i)); }
        ParameterInfo legacy{}, toggle{}, fade{};
        control->getParameterInfo(hasio::LegacyCrossfade, legacy); assert(legacy.flags & ParameterInfo::kIsHidden);
        control->getParameterInfo(hasio::KeepSpeed, toggle); assert(toggle.stepCount == 1 && toggle.defaultNormalizedValue == 1);
        control->getParameterInfo(hasio::FadeIn, fade); assert(fade.flags & ParameterInfo::kCanAutomate);
        assert(processor->getLatencySamples() == hasio::Engine::latencySamples());
        ProcessSetup setup{}; setup.sampleRate = 48000; setup.maxSamplesPerBlock = 256; setup.symbolicSampleSize = kSample32;
        assert(processor->setupProcessing(setup) == kResultOk); comp->setActive(true); processor->setProcessing(true);
        std::array<float, 256> left{}, right{}; float* channels[] = {left.data(), right.data()};
        AudioBusBuffers buffers{}; buffers.numChannels = 2; buffers.channelBuffers32 = channels;
        ProcessData data{}; data.numSamples = 256; data.numOutputs = 1; data.outputs = &buffers;
        Events events; Event note{}; note.type = Event::kNoteOnEvent; note.sampleOffset = 64; note.noteOn.pitch = 60; note.noteOn.velocity = 1; note.noteOn.noteId = 1; events.list.push_back(note); data.inputEvents = &events;
        assert(processor->process(data) == kResultOk);
        data.inputEvents = nullptr;
        for (auto v : left) assert(v == 0);
        for (int block = 1; block < hasio::Engine::latencySamples() / 256; ++block) {
            assert(processor->process(data) == kResultOk); for (auto v : left) assert(v == 0);
        }
        assert(processor->process(data) == kResultOk);
        for (int i = 0; i < 64; ++i) assert(left[i] == 0 && right[i] == 0);
        float peak = 0; for (int i = 64; i < 256; ++i) peak = std::max(peak, std::abs(left[i])); assert(peak > .001);
        data.inputEvents = nullptr;
        // Changing direction kills the old voice exactly at the automation point.
        Changes changes; changes.queue.points = {{128, .5}}; data.inputParameterChanges = &changes;
        assert(processor->process(data) == kResultOk);
        bool nonzero = false; for (int i = 0; i < 128; ++i) nonzero |= std::abs(left[i]) > .0001f; assert(nonzero);
        for (int i = 128; i < 256; ++i) assert(left[i] == 0);
        data.inputParameterChanges = nullptr;
        control->setParamNormalized(hasio::Root, 48.0 / 127);
        control->setParamNormalized(hasio::FadeIn, hasio::normalized(hasio::FadeIn, 25));
        control->setParamNormalized(hasio::FadeOut, hasio::normalized(hasio::FadeOut, 75));
        Stream state; assert(comp->getState(&state) == kResultOk && state.bytes.size() > 1000000);
        control->setParamNormalized(hasio::Root, 72.0 / 127); state.pos = 0;
        assert(comp->setState(&state) == kResultOk); assert(std::abs(control->getParamNormalized(hasio::Root) - 48.0 / 127) < 1.e-9);
        assert(std::abs(control->normalizedParamToPlain(hasio::FadeIn, control->getParamNormalized(hasio::FadeIn)) - 25) < 1.e-9);
        assert(std::abs(control->normalizedParamToPlain(hasio::FadeOut, control->getParamNormalized(hasio::FadeOut)) - 75) < 1.e-9);
        auto truncated = state; truncated.bytes.resize(20); truncated.pos = 0; assert(comp->setState(&truncated) != kResultOk);
        // The embedded sample is sufficient for a second fresh instance.
        IComponent* second = nullptr; factory->createInstance(info.cid, IComponent_iid, reinterpret_cast<void**>(&second)); second->initialize(nullptr); state.pos = 0;
        assert(second->setState(&state) == kResultOk); second->terminate(); second->release();
        processor->setProcessing(false); comp->setActive(false);
        setup.symbolicSampleSize = kSample64; setup.sampleRate = 44100; assert(processor->setupProcessing(setup) == kResultOk);
        std::array<double, 256> dleft{}, dright{}; double* dchannels[] = {dleft.data(), dright.data()}; buffers.channelBuffers64 = dchannels; data.symbolicSampleSize = kSample64;
        comp->setActive(true); processor->setProcessing(true); data.inputEvents = &events; assert(processor->process(data) == kResultOk);
        data.inputEvents = nullptr; peak = 0;
        for (int block = 0; block < 24; ++block) {
            assert(processor->process(data) == kResultOk);
            for (auto v : dleft) { assert(std::isfinite(v)); peak = std::max(peak, static_cast<float>(std::abs(v))); }
        }
        assert(peak > .001);
        // Feed tempo/time signature through the actual VST3 ProcessContext and
        // measure the resulting one-shot output, not just controller values.
        processor->setProcessing(false); comp->setActive(false);
        setup.symbolicSampleSize = kSample32; setup.sampleRate = 48000;
        assert(processor->setupProcessing(setup) == kResultOk);
        buffers.channelBuffers32 = channels; data.symbolicSampleSize = kSample32;
        hasio::Model syncModel; auto tone = std::make_shared<hasio::Sample>(); tone->rate = 48000;
        for (int i = 0; i < 48000; ++i) tone->left.push_back(float(.5 * std::sin(2 * 3.141592653589793 * 220 * i / 48000)));
        tone->right = tone->left; tone->buildPeaks(); syncModel.samples.publish(tone);
        syncModel.params[hasio::ModeId].store(hasio::normalized(hasio::ModeId, 0));
        syncModel.params[hasio::SyncLength].store(hasio::normalized(hasio::SyncLength, 3));
        syncModel.params[hasio::Tempo].store(hasio::normalized(hasio::Tempo, 150));
        auto payload = hasio::saveState(syncModel);
        Stream syncState; uint64_t payloadSize = payload.size(); int32 written;
        syncState.write(&payloadSize, sizeof(payloadSize), &written); syncState.write(payload.data(), static_cast<int32>(payload.size()), &written);
        auto checkLength = [&](double bpm, int numerator, int denominator, double duration, bool provideContext) {
            processor->setProcessing(false); syncState.pos = 0; assert(comp->setState(&syncState) == kResultOk);
            comp->setActive(true); processor->setProcessing(true);
            ProcessContext context{}; context.state = ProcessContext::kTempoValid | ProcessContext::kTimeSigValid;
            context.tempo = bpm; context.timeSigNumerator = numerator; context.timeSigDenominator = denominator;
            data.processContext = provideContext ? &context : nullptr;
            events.list[0].sampleOffset = 0; data.inputEvents = &events;
            int blocks = static_cast<int>(std::ceil((duration + .2) * 48000 / 256)); bool soundingNearEnd = false;
            for (int block = 0; block < blocks; ++block) {
                assert(processor->process(data) == kResultOk); data.inputEvents = nullptr;
                double time = block * 256.0 / 48000;
                for (float v : left) {
                    assert(std::isfinite(v));
                    if (time > duration - .25 && time < duration - .15) soundingNearEnd |= std::abs(v) > .001;
                    if (time > duration + .15) assert(std::abs(v) < 1.e-6);
                }
            }
            assert(soundingNearEnd);
        };
        checkLength(120, 4, 4, 2, true); checkLength(120, 7, 8, 1.75, true);
        checkLength(60, 3, 4, 3, true); checkLength(0, 0, 0, 1.6, false);
        checkLength(NAN, -1, 0, 1.6, true);
        data.processContext = nullptr;
        // Actual VST3 FX automation affects audio at its offset and is stateful.
        auto renderFx = [&](bool distortion, bool chorus) {
            processor->setProcessing(false); syncState.pos=0; assert(comp->setState(&syncState)==kResultOk);
            control->setParamNormalized(hasio::ModeId,hasio::normalized(hasio::ModeId,1));
            control->setParamNormalized(hasio::SyncLength,0);
            control->setParamNormalized(hasio::DistAmount,.8);
            control->setParamNormalized(hasio::ChorusEnabled,chorus ? 1 : 0);
            control->setParamNormalized(hasio::ChorusMix,.8);
            processor->setProcessing(true); std::vector<float> rendered;
            for(int block=0;block<120;++block) {
                data.inputEvents=block==0 ? &events : nullptr;
                changes.queue.id=hasio::DistEnabled; changes.queue.points={{128,1}};
                data.inputParameterChanges=distortion && block==20 ? &changes : nullptr;
                assert(processor->process(data)==kResultOk);
                for(float v:left) { assert(std::isfinite(v)); rendered.push_back(v); }
            }
            data.inputEvents=nullptr; data.inputParameterChanges=nullptr; return rendered;
        };
        auto dry=renderFx(false,false), distorted=renderFx(true,false), chorused=renderFx(false,true);
        double distDelta=0, chorusDelta=0;
        for(size_t i=0;i<dry.size();++i) {
            if(i<20*256+128) assert(dry[i]==distorted[i]);
            else distDelta+=std::abs(dry[i]-distorted[i]);
            chorusDelta+=std::abs(dry[i]-chorused[i]);
        }
        assert(distDelta>10 && chorusDelta>10);
        control->setParamNormalized(hasio::ChorusRate,hasio::normalized(hasio::ChorusRate,2.5));
        Stream fxState; assert(comp->getState(&fxState)==kResultOk);
        control->setParamNormalized(hasio::ChorusRate,0); fxState.pos=0; assert(comp->setState(&fxState)==kResultOk);
        assert(std::abs(control->normalizedParamToPlain(hasio::ChorusRate,control->getParamNormalized(hasio::ChorusRate))-2.5)<1.e-9);
        auto* editor = control->createView(ViewType::kEditor); assert(editor);
        assert(editor->onKeyDown('s', 0, 1) == kResultFalse && editor->onKeyUp('s', 0, 1) == kResultFalse);
#ifdef _WIN32
        assert(editor->isPlatformTypeSupported(kPlatformTypeHWND) == kResultTrue);
        assert(editor->isPlatformTypeSupported(kPlatformTypeNSView) == kResultFalse);
        ViewRect size; assert(editor->getSize(&size) == kResultOk);
        WNDCLASSW wc{}; wc.lpfnWndProc = hostWindowProc; wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"EssentialSamplerTestHost";
        assert(RegisterClassW(&wc));
        HWND parent = CreateWindowW(wc.lpszClassName, L"Test host", WS_OVERLAPPEDWINDOW,
            0, 0, size.getWidth(), size.getHeight(), nullptr, nullptr, wc.hInstance, nullptr);
        assert(parent); ShowWindow(parent, SW_SHOW); SetFocus(parent);
        assert(editor->attached(parent, kPlatformTypeHWND) == kResultOk);
        HWND child = GetWindow(parent, GW_CHILD); assert(child);
        RECT bounds{}; assert(GetClientRect(child, &bounds)); assert(bounds.right == size.getWidth() && bounds.bottom == size.getHeight());
        SendMessageW(child, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(400, 350));
        SendMessageW(child, WM_LBUTTONUP, 0, MAKELPARAM(400, 350));
        assert(GetFocus() == parent);
        SendMessageW(GetFocus(), WM_KEYDOWN, VK_BACK, 0); assert(hostBackspaces == 1);
        assert(editor->onKeyDown(127, 1, 0) == kResultFalse && editor->onKeyUp(127, 1, 0) == kResultFalse);
        assert(editor->onFocus(false) == kResultOk);
        assert(editor->removed() == kResultOk && GetWindow(parent, GW_CHILD) == nullptr);
        // A host may reuse the view after closing and reopening its window.
        assert(editor->attached(parent, kPlatformTypeHWND) == kResultOk);
        assert(editor->removed() == kResultOk); editor->release();
        DestroyWindow(parent); UnregisterClassW(wc.lpszClassName, wc.hInstance);
#else
        assert(editor->isPlatformTypeSupported(kPlatformTypeNSView) == kResultTrue);
        ViewRect editorSize; assert(editor->getSize(&editorSize) == kResultOk);
        HostEditorSurface* parent = [[HostEditorSurface alloc] initWithFrame:NSMakeRect(0, 0, editorSize.getWidth(), editorSize.getHeight())];
        NSWindow* hostWindow = [[NSWindow alloc] initWithContentRect:parent.bounds styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        hostWindow.contentView = parent;
        assert([hostWindow makeFirstResponder:parent]);
        assert(editor->attached((__bridge void*)parent, kPlatformTypeNSView) == kResultOk); assert(parent.subviews.count == 1);
        assert(parent.subviews[0].bounds.size.width == editorSize.getWidth() && parent.subviews[0].bounds.size.height == editorSize.getHeight());
        NSView* child = parent.subviews.firstObject;
        NSPoint point = [child convertPoint:NSMakePoint(400, 350) toView:nil];
        NSEvent* click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:0 windowNumber:hostWindow.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [child mouseDown:click]; [child mouseUp:click];
        assert(hostWindow.firstResponder == parent); // clicking the plugin must not steal DAW keyboard focus
        auto backspace = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:hostWindow.windowNumber context:nil characters:@"\x7f" charactersIgnoringModifiers:@"\x7f" isARepeat:NO keyCode:51];
        [hostWindow sendEvent:backspace]; assert(parent.backspaces == 1);
        // Backspace inside a numeric text edit belongs to that field, then commit
        // returns focus to the host so subsequent Backspace is a DAW command.
        NSTextField* field=(NSTextField*)[child viewWithTag:hasio::Start];
        [field selectText:nil]; NSTextView* fieldEditor=(NSTextView*)field.currentEditor;
        assert(fieldEditor); fieldEditor.string=@"12"; fieldEditor.selectedRange=NSMakeRange(2,0);
        [hostWindow sendEvent:backspace]; assert([fieldEditor.string isEqualToString:@"1"] && parent.backspaces==1);
        [NSApp sendAction:field.action to:field.target from:field];
        assert(hostWindow.firstResponder==parent);
        [hostWindow sendEvent:backspace]; assert(parent.backspaces==2);
        for (NSInteger tag : {NSInteger(hasio::Root), NSInteger(1002), NSInteger(hasio::SyncLength), NSInteger(hasio::DistType)}) {
            [field selectText:nil]; assert(field.currentEditor);
            NSControl* choice=(NSControl*)[child viewWithTag:tag];
            [NSApp sendAction:choice.action to:choice.target from:choice];
            assert(hostWindow.firstResponder==parent);
        }
        assert(editor->onKeyDown(127, 1, 0) == kResultFalse && editor->onKeyUp(127, 1, 0) == kResultFalse);
        assert(editor->removed() == kResultOk && parent.subviews.count == 0); editor->release();
#endif
        processor->setProcessing(false); comp->setActive(false); comp->terminate();
        control->release(); processor->release(); comp->release(); factory->release(); assert(exit());
#ifdef _WIN32
        assert(FreeLibrary(handle));
        // Reopening a DLL in the same host must not reuse a window class whose
        // procedure pointed into the unloaded module.
        handle = LoadLibraryA(argv[1]); assert(handle);
        auto reentry = reinterpret_cast<bool (*)()>(GetProcAddress(handle, "InitDll"));
        auto reexit = reinterpret_cast<bool (*)()>(GetProcAddress(handle, "ExitDll"));
        auto refactory = reinterpret_cast<IPluginFactory* (*)()>(GetProcAddress(handle, "GetPluginFactory"));
        assert(reentry && reexit && refactory && reentry());
        factory = refactory(); comp = nullptr; control = nullptr;
        assert(factory->createInstance(info.cid, IComponent_iid, reinterpret_cast<void**>(&comp)) == kResultOk);
        assert(comp->initialize(nullptr) == kResultOk);
        assert(comp->queryInterface(IEditController_iid, reinterpret_cast<void**>(&control)) == kResultOk);
        editor = control->createView(ViewType::kEditor); assert(editor);
        assert(RegisterClassW(&wc));
        parent = CreateWindowW(wc.lpszClassName, L"Reopened host", WS_OVERLAPPEDWINDOW,
            0, 0, size.getWidth(), size.getHeight(), nullptr, nullptr, wc.hInstance, nullptr);
        assert(parent && editor->attached(parent, kPlatformTypeHWND) == kResultOk);
        assert(editor->removed() == kResultOk); editor->release();
        DestroyWindow(parent); UnregisterClassW(wc.lpszClassName, wc.hInstance);
        comp->terminate(); control->release(); comp->release(); factory->release();
        assert(reexit() && FreeLibrary(handle));
#endif
        // Cocoa classes remain resident until process exit on macOS.
        std::cout << "PASS: native VST3 load, factory, single component/controller, stereo/MIDI buses, 32/64-bit render, sample-accurate note and automation offsets, portable state, malformed state, editor lifecycle\n";
    }
}
