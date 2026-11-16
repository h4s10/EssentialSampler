#include "Editor.hpp"
#include <cassert>
#include <iostream>
using namespace hasio;

@interface HostKeys : NSResponder
@property(nonatomic) int downs, ups, flags;
@property(nonatomic, strong) NSEvent* lastEvent;
@end
@implementation HostKeys
- (void)keyDown:(NSEvent*)event { ++_downs; _lastEvent = event; }
- (void)keyUp:(NSEvent*)event { ++_ups; _lastEvent = event; }
- (void)flagsChanged:(NSEvent*)event { ++_flags; _lastEvent = event; }
@end

int main() {
    @autoreleasepool {
        [NSApplication sharedApplication];
        auto model = std::make_shared<Model>();
        NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 860) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        HLView* view = [[HLView alloc] initWithModel:model]; window.contentView = view;
        HostKeys* host = [HostKeys new]; view.nextResponder = host;
        auto key = [&](NSEventType type, unsigned short code, NSString* chars, NSEventModifierFlags flags = 0, bool repeat = false) {
            return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:window.windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:repeat keyCode:code];
        };
        Note note;
        while (model->notes.pop(note)) {}
        auto empty = [&] { assert(!model->notes.pop(note)); };
        auto expectNote = [&](bool on, int pitch) { assert(model->notes.pop(note) && !note.stopPreview && note.on == on && note.pitch == pitch); };
        auto pass = [&](unsigned short code, NSString* chars, NSEventModifierFlags flags = 0, bool repeat = false) {
            int downs = host.downs, ups = host.ups;
            NSEvent* down = key(NSEventTypeKeyDown, code, chars, flags, repeat);
            assert(![view performKeyEquivalent:down]); [view keyDown:down];
            assert(host.downs == downs + 1 && host.lastEvent == down);
            NSEvent* up = key(NSEventTypeKeyUp, code, chars, flags);
            [view keyUp:up]; assert(host.ups == ups + 1 && host.lastEvent == up); empty();
            assert(!model->panic.load());
        };
        for (auto entry : std::array<std::pair<unsigned short, unichar>, 14>{{
            {53, 27}, {36, '\r'}, {76, 3}, {49, ' '}, {48, '\t'}, {51, 127}, {117, NSDeleteFunctionKey},
            {123, NSLeftArrowFunctionKey}, {124, NSRightArrowFunctionKey}, {125, NSDownArrowFunctionKey}, {126, NSUpArrowFunctionKey},
            {115, NSHomeFunctionKey}, {119, NSEndFunctionKey}, {116, NSPageUpFunctionKey}}}) {
            auto ch = entry.second; auto chars = [NSString stringWithCharacters:&ch length:1];
            pass(entry.first, chars); pass(entry.first, chars, 0, true);
        }
        for (unichar ch = NSF1FunctionKey; ch <= NSF35FunctionKey; ++ch) pass(122, [NSString stringWithCharacters:&ch length:1]);
        pass(11, @"b"); pass(0, @"");
        const NSEventModifierFlags modifiers[] = {NSEventModifierFlagCommand, NSEventModifierFlagControl, NSEventModifierFlagOption, NSEventModifierFlagShift, NSEventModifierFlagFunction, NSEventModifierFlagCapsLock, NSEventModifierFlagNumericPad, NSEventModifierFlagHelp};
        for (int mask = 1; mask < 256; ++mask) {
            NSEventModifierFlags flags = 0;
            for (int bit = 0; bit < 8; ++bit) if (mask & (1 << bit)) flags |= modifiers[bit];
            pass(0, @"a", flags); pass(1, @"s", flags, true);
        }
        // Only an owned, unmodified musical key is consumed; repeats do not retrigger.
        int downs = host.downs;
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a", 0, true)]; empty(); assert(host.downs == downs);
        [view keyUp:key(NSEventTypeKeyUp, 0, @"different layout")]; expectNote(false, 60); empty();
        pass(0, @"a", 0, true); // a repeat whose original keyDown belonged to the host
        // A changed modifier on keyUp still releases the owned note and reaches the host.
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
        int ups = host.ups;
        [view keyUp:key(NSEventTypeKeyUp, 0, @"A", NSEventModifierFlagShift)];
        expectNote(false, 60); assert(host.ups == ups + 1); empty();
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
        auto flags = key(NSEventTypeFlagsChanged, 55, @"", NSEventModifierFlagCommand);
        [view flagsChanged:flags]; expectNote(false, 60); assert(host.flags == 1 && host.lastEvent == flags);
        [view keyUp:key(NSEventTypeKeyUp, 0, @"a", NSEventModifierFlagCommand)]; empty();
        // Window/app focus loss sends a dedicated stop for UI voices, even in one-shot mode.
        auto focusStop = [&](NSNotificationName name, id object) {
            [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
            [[NSNotificationCenter defaultCenter] postNotificationName:name object:object];
            expectNote(false, 60); assert(model->notes.pop(note) && note.stopPreview); empty();
            [view keyUp:key(NSEventTypeKeyUp, 0, @"a")]; empty();
        };
        focusStop(NSWindowDidResignKeyNotification, window);
        focusStop(NSApplicationDidResignActiveNotification, NSApp);
        NSWindow* other = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:0 backing:NSBackingStoreBuffered defer:NO];
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object:other]; empty();
        [view resignFirstResponder]; expectNote(false, 60); assert(model->notes.pop(note) && note.stopPreview); empty();
        NSPoint point = [view convertPoint:NSMakePoint(165, 810) toView:nil];
        auto mouse = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:0 windowNumber:window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
        [view mouseDown:mouse]; expectNote(true, 48);
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object:window];
        expectNote(false, 48); assert(model->notes.pop(note) && note.stopPreview); empty();
        [view mouseUp:mouse]; empty(); // delayed mouse release must not leave a note or duplicate note-off
        [view keyDown:key(NSEventTypeKeyDown, 0, @"a")]; expectNote(true, 60);
        [view detach]; expectNote(false, 60); assert(model->notes.pop(note) && note.stopPreview); empty();
        [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification object:window]; empty();
        std::cout << "PASS: reserved keys and 255 modifier combinations reach host; note ownership, repeats, layout changes, window/app/focus/detach release\n";
    }
}
