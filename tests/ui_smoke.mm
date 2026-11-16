#include "Editor.hpp"
#include "AudioFile.hpp"
#include <cassert>
#include <iostream>
using namespace hasio;
@interface HLView (TestRefresh)
- (void)refreshTimingControls;
@end
int main(int argc, char** argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        auto model = std::make_shared<Model>();
        NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 860) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        HLView* view = [[HLView alloc] initWithModel:model]; window.contentView = view;
        // Native numeric region fields must edit the real loop, not just display text.
        auto* startField = static_cast<NSTextField*>([view viewWithTag:Start]);
        auto* endField = static_cast<NSTextField*>([view viewWithTag:End]);
        auto* lengthField = static_cast<NSTextField*>([view viewWithTag:1001]);
        auto* rootMenu = static_cast<NSPopUpButton*>([view viewWithTag:Root]);
        assert(startField && endField && lengthField && rootMenu);
        auto enter = [&](NSTextField* field, NSString* value) { field.stringValue = value; [NSApp sendAction:field.action to:field.target from:field]; };
        enter(startField, @"0.600 s"); enter(endField, @"1.800 s");
        assert(std::abs(model->params[Start] - .2) < 1.e-6 && std::abs(model->params[End] - .6) < 1.e-6);
        enter(lengthField, @"0.900"); assert(std::abs(model->params[End] - .5) < 1.e-6);
        enter(startField, @"invalid"); assert(std::abs(model->params[Start] - .2) < 1.e-6);
        enter(lengthField, @"999"); assert(model->params[End] == 1);
        enter(endField, @"-1"); assert(model->params[End] > model->params[Start]);
        [rootMenu selectItemAtIndex:48]; [NSApp sendAction:rootMenu.action to:rootMenu.target from:rootMenu];
        assert(plain(Root, model->params[Root]) == 48);
        [rootMenu selectItemAtIndex:60]; [NSApp sendAction:rootMenu.action to:rootMenu.target from:rootMenu];
        model->params[Start].store(.2); model->params[End].store(.6);
        model->params[Tune].store(normalized(Tune, 7));
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        [view refreshTimingControls]; [view display];
        NSBitmapImageRep* bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        assert([png writeToFile:@"build/ui-preview.png" atomically:YES]);
        model->params[Tune].store(defaults[Tune]);
        // Test real Cocoa event dispatch through the view, including automation gesture pairing.
        int begins = 0, changes = 0, ends = 0;
        [view setBeginEdit:[&](uint32_t) { ++begins; }
                   change:[&](uint32_t, double) { ++changes; }
                      end:[&](uint32_t) { ++ends; }
                    dirty:[] {}];
        auto mouse = [&](NSEventType type, double x, double y, int clicks = 1) {
            NSPoint point = [view convertPoint:NSMakePoint(x, y) toView:nil];
            return [NSEvent mouseEventWithType:type location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:clicks pressure:1];
        };
        auto close = [](double a, double b) { if (std::abs(a - b) >= 1.e-6) { std::cerr << "Expected " << b << ", got " << a << '\n'; std::abort(); } };
        auto x = [](double t) { return 28 + 884 * t; };
        auto click = [&](double px, double py, int count = 1) {
            [view mouseDown:mouse(NSEventTypeLeftMouseDown, px, py, count)];
            [view mouseUp:mouse(NSEventTypeLeftMouseUp, px, py, count)];
        };
        auto drag = [&](double ax, double ay, double bx, double by) {
            [view mouseDown:mouse(NSEventTypeLeftMouseDown, ax, ay)];
            [view mouseDragged:mouse(NSEventTypeLeftMouseDragged, bx, by)];
            [view mouseUp:mouse(NSEventTypeLeftMouseUp, bx, by)];
        };
        model->params[Start].store(.2); model->params[End].store(.6);
        click(x(.4), 350); close(model->params[Start], .2); close(model->params[End], .6);
        drag(x(.4), 350, x(.55), 350);
        close(model->params[Start], .35); close(model->params[End], .75);
        drag(x(.5), 350, 1000, 350); close(model->params[Start], .6); close(model->params[End], 1);
        drag(x(.8), 350, -100, 350); close(model->params[Start], 0); close(model->params[End], .4);
        model->params[Start].store(.2); model->params[End].store(.6);
        click(x(.1), 350); close(model->params[Start], .1); close(model->params[End], .6);
        click(x(.8), 350); close(model->params[Start], .1); close(model->params[End], .8);
        drag(x(.1) + 13, 240, x(.2) + 13, 240); close(model->params[Start], .2); close(model->params[End], .8);
        drag(x(.8) - 13, 240, x(.7) - 13, 240); close(model->params[Start], .2); close(model->params[End], .7);
        drag(x(.2) + 2, 350, x(.3) + 2, 350); close(model->params[Start], .3); close(model->params[End], .8);
        assert(begins == ends && changes > 0);
        click(1230, 350); close(model->params[KeepSpeed], 0);
        click(1230, 350); close(model->params[KeepSpeed], 1);
        double gain = model->params[Gain].load(); drag(858, 688, 858, 652);
        assert(model->params[Gain] > gain); click(858, 688, 2); close(model->params[Gain], defaults[Gain]);
        click(206, 673); assert(plain(FadeIn, model->params[FadeIn]) > 50);
        click(220, 714); assert(plain(FadeOut, model->params[FadeOut]) > 100);
        assert(begins == ends);
        [view mouseDown:mouse(NSEventTypeLeftMouseDown, 647, 560)]; // Ping-pong mode
        assert(plain(ModeId, model->params[ModeId].load()) == 3);
        [view mouseDown:mouse(NSEventTypeLeftMouseDown, 805, 511)]; // zoom in
        drag(470, 350, 558.4, 350); close(model->params[Start], .35); close(model->params[End], .85);
        [view refreshTimingControls]; [view display];
        bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/ui-zoom-preview.png" atomically:YES]);
        [view mouseDown:mouse(NSEventTypeLeftMouseDown, 165, 810)];
        [view mouseUp:mouse(NSEventTypeLeftMouseUp, 165, 810)];
        Note note; assert(model->notes.pop(note) && note.on && note.pitch == 48);
        assert(model->notes.pop(note) && !note.on && note.pitch == 48);
        auto* length = static_cast<NSPopUpButton*>([view viewWithTag:SyncLength]);
        auto* bpm = static_cast<NSTextField*>([view viewWithTag:Tempo]); assert(length && bpm);
        drag(1110, 437, 1300, 437); close(plain(PlaybackRate, model->params[PlaybackRate]), 4);
        click(1110, 437, 2); close(plain(PlaybackRate, model->params[PlaybackRate]), 1);
        model->params[KeepSpeed].store(0);
        [length selectItemAtIndex:2]; [NSApp sendAction:length.action to:length.target from:length];
        close(plain(SyncLength, model->params[SyncLength]), 3);
        drag(1110, 437, 1300, 437); close(plain(PlaybackRate, model->params[PlaybackRate]), 1);
        click(1230, 350); close(model->params[KeepSpeed], 0); // sync fixes duration regardless of stored toggle
        bpm.stringValue = @"150"; [NSApp sendAction:bpm.action to:bpm.target from:bpm]; close(model->settings().tempo, 150);
        bpm.stringValue = @"invalid"; [NSApp sendAction:bpm.action to:bpm.target from:bpm]; close(model->settings().tempo, 150);
        model->setHostTiming(130, 7, 8);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        assert(!bpm.enabled); close(bpm.doubleValue, 130); close(model->settings().beatsPerBar, 3.5);
        assert(begins == ends);
        [view refreshTimingControls]; [view display]; bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
        [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/ui-sync-preview.png" atomically:YES]);
        // Switching Free/Sync restores the last musical duration.
        auto* sync = static_cast<NSSegmentedControl*>([view viewWithTag:1002]); assert(sync);
        sync.selectedSegment = 0; [NSApp sendAction:sync.action to:sync.target from:sync]; close(plain(SyncLength, model->params[SyncLength]), 0);
        sync.selectedSegment = 1; [NSApp sendAction:sync.action to:sync.target from:sync]; close(plain(SyncLength, model->params[SyncLength]), 3);
        while (model->notes.pop(note)) {}
        click(92, 798); // octave up
        while (model->notes.pop(note)) {}
        click(165, 810); assert(model->notes.pop(note) && note.on && note.pitch == 60);
        assert(model->notes.pop(note) && !note.on && note.pitch == 60);
        click(48, 798); // octave down
        while (model->notes.pop(note)) {}
        click(1005, 610); click(1005, 649); // former Preview/Panic locations have no actions
        assert(!model->panic.load() && !model->notes.pop(note));
        // Short regions must leave both S and E independently reachable at sample edges.
        click(875, 511); // Fit
        model->params[Start].store(.99); model->params[End].store(1);
        drag(898, 270, 893.58, 270); close(model->params[Start], .99); close(model->params[End], .995);
        model->params[Start].store(0); model->params[End].store(.01);
        drag(42, 240, 46.42, 240); close(model->params[Start], .005); close(model->params[End], .01);
        drag(42, 270, 46.42, 270); close(model->params[Start], .005); close(model->params[End], .015);
        // FX is a real separate page: sampler controls hide, automation stays paired.
        int fxBegins = begins, fxEnds = ends;
        click(150, 92);
        auto* distType = static_cast<NSPopUpButton*>([view viewWithTag:DistType]);
        assert(!distType.hidden && startField.hidden && rootMenu.hidden);
        click(580, 163); click(1200, 163);
        close(model->params[DistEnabled], 1); close(model->params[ChorusEnabled], 1);
        [distType selectItemAtIndex:4]; [NSApp sendAction:distType.action to:distType.target from:distType];
        close(plain(DistType, model->params[DistType]), 4);
        const uint32_t params[] = {DistAmount, DistTone, DistMix, ChorusDepth, ChorusRate, ChorusWidth, ChorusDelay, ChorusFeedback, ChorusMix};
        for (int i=0;i<9;++i) {
            double x0=i<3 ? 52 : 676+((i-3)%2)*298;
            double y=i<3 ? 323+i*100 : 323+((i-3)/2)*100;
            double width=i<3 ? 548 : 254;
            drag(x0+width*.1,y,x0+width*.7,y); close(model->params[params[i]], .7);
            click(x0+width*.4,y,2); close(model->params[params[i]], defaults[params[i]]);
        }
        assert(begins-fxBegins == ends-fxEnds);
        double savedStart=model->params[Start], savedEnd=model->params[End];
        click(400,350); close(model->params[Start],savedStart); close(model->params[End],savedEnd);
        model->params[DistAmount]=.55;
        [view refreshTimingControls]; [view display]; [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
        assert([[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/ui-fx-preview.png" atomically:YES]);
        while(model->notes.pop(note)) {}
        click(165,810); assert(model->notes.pop(note) && note.on); assert(model->notes.pop(note) && !note.on);
        click(60,92); assert(distType.hidden && !startField.hidden && !rootMenu.hidden);
        close(model->params[DistAmount],.55); close(model->params[ChorusEnabled],1);
        [view detach];
        std::string error;
        assert(!loadAudioFile("build/file-that-does-not-exist.wav", error)); assert(!error.empty());
        for (int i = 1; i < argc; ++i) {
            auto sample = loadAudioFile(argv[i], error);
            if (!sample) std::cerr << argv[i] << ": " << error << '\n';
            else std::cout << argv[i] << ": " << sample->frames() << " frames, " << sample->rate << " Hz\n";
            assert(sample && sample->frames() == 48000 && sample->rate == 48000);
            assert(*std::max_element(sample->left.begin(), sample->left.end()) > .49f);
        }
        std::cout << "PASS: native render, loop translation/clamping, outside bounds, S/E grabs, zoomed dragging, Keep speed, output knob, fades, gestures, file decoding\n";
    }
}
