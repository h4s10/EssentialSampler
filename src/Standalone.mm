#include "Editor.hpp"
#import <AudioToolbox/AudioToolbox.h>
using namespace hasio;
@interface HLApp : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end
@implementation HLApp {
    NSWindow* _window;
    HLView* _view;
    std::shared_ptr<Model> _model;
    Engine _engine;
    AudioUnit _unit;
}
static OSStatus renderAudio(void* context, AudioUnitRenderActionFlags*, const AudioTimeStamp*, UInt32, UInt32 frames, AudioBufferList* output) {
    HLApp* app = (__bridge HLApp*)context;
    return [app render:frames output:output];
}
- (OSStatus)render:(UInt32)frames output:(AudioBufferList*)output {
    _engine.setSample(_model->samples.pin()); _engine.configure(_model->settings());
    if (_model->panic.exchange(false)) _engine.allNotesOff();
    Note n; while (_model->notes.pop(n)) _engine.previewEvent(n);
    float peak = 0;
    for (UInt32 i = 0; i < frames; ++i) {
        float l, r; _engine.render(l, r); peak = std::max({peak, std::abs(l), std::abs(r)});
        for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
            auto& buffer = output->mBuffers[b]; auto* samples = static_cast<float*>(buffer.mData);
            if (!samples) continue;
            for (UInt32 ch = 0; ch < buffer.mNumberChannels; ++ch) samples[i * buffer.mNumberChannels + ch] = (b + ch) == 0 ? l : r;
        }
    }
    _model->meter.store(std::max(peak, _model->meter.load() * .92f)); _model->activeVoices.store(_engine.activeCount());
    _model->playhead.store(_engine.playhead()); _model->samples.unpin(); return noErr;
}
- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    _model = std::make_shared<Model>(); _engine.prepare(48000);
    NSMenu* menu = [NSMenu new]; NSMenuItem* appItem = [NSMenuItem new]; [menu addItem:appItem];
    NSMenu* sub = [NSMenu new]; [sub addItemWithTitle:@"Quit Essential Sampler" action:@selector(terminate:) keyEquivalent:@"q"]; appItem.submenu = sub; NSApp.mainMenu = menu;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, editorWidth, editorHeight) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Essential Sampler"; _window.delegate = self; _window.releasedWhenClosed = NO;
    _view = [[HLView alloc] initWithModel:_model]; _window.contentView = _view;
    [_window center]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    AudioComponentDescription desc{}; desc.componentType = kAudioUnitType_Output; desc.componentSubType = kAudioUnitSubType_DefaultOutput; desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    OSStatus status = component ? AudioComponentInstanceNew(component, &_unit) : -1;
    AudioStreamBasicDescription format{}; format.mSampleRate = 48000; format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBitsPerChannel = 32; format.mChannelsPerFrame = 2; format.mFramesPerPacket = 1; format.mBytesPerFrame = format.mBytesPerPacket = 4;
    AURenderCallbackStruct callback{renderAudio, (__bridge void*)self};
    if (!status) status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    if (!status) status = AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    if (!status) status = AudioUnitInitialize(_unit);
    if (!status) status = AudioOutputUnitStart(_unit);
    if (status) _model->setStatus("Audio output unavailable. Check the macOS default output device.");
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification*)notification {
    (void)notification; [_view detach];
    if (_unit) { AudioOutputUnitStop(_unit); AudioUnitUninitialize(_unit); AudioComponentInstanceDispose(_unit); _unit = nullptr; }
}
@end
int main() {
    @autoreleasepool { [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; HLApp* delegate = [HLApp new]; NSApp.delegate = delegate; [NSApp run]; }
    return 0;
}
