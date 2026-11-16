#include "Editor.hpp"
#include "AudioFile.hpp"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cstdio>

using namespace hasio;
namespace {
NSColor* colour(unsigned rgb, CGFloat alpha = 1) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:alpha];
}
void box(NSRect r, unsigned fill, CGFloat radius = 8, unsigned border = 0) {
    auto p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
    [colour(fill) setFill]; [p fill];
    if (border) { [colour(border) setStroke]; p.lineWidth = 1; [p stroke]; }
}
void label(NSString* text, NSRect rect, CGFloat size = 12, unsigned color = 0x9bacbb, bool bold = false, NSTextAlignment alignment = NSTextAlignmentLeft) {
    NSMutableParagraphStyle* paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = alignment; paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular],
        NSForegroundColorAttributeName:colour(color), NSParagraphStyleAttributeName:paragraph}];
}
void line(double x1, double y1, double x2, double y2, unsigned color, double width = 1) {
    [colour(color) setStroke]; auto path = [NSBezierPath bezierPath]; path.lineWidth = width;
    [path moveToPoint:NSMakePoint(x1, y1)]; [path lineToPoint:NSMakePoint(x2, y2)]; [path stroke];
}
NSString* valueText(uint32_t p, double normalizedValue) {
    double v = plain(p, normalizedValue);
    if (p == Root) {
        const char* notes[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
        int note = static_cast<int>(v);
        return [NSString stringWithFormat:@"%s%d · %d", notes[note % 12], note / 12 - 1, note];
    }
    if (p == Gain) return [NSString stringWithFormat:@"%+.1f dB", v];
    if (p == Tune) return [NSString stringWithFormat:@"%+.1f st", v];
    return [NSString stringWithFormat:@"%.1f ms", v];
}
bool isBlack(int note) { int n = note % 12; return n == 1 || n == 3 || n == 6 || n == 8 || n == 10; }
NSRect overview() { return NSMakeRect(28, 126, 884, 54); }
NSRect detail() { return NSMakeRect(28, 218, 884, 255); }
NSRect keyboard() { return NSMakeRect(146, 752, 946, 76); }
NSRect tabButton(int index) { return NSMakeRect(28 + index * 83, 78, 80, 28); }
constexpr uint32_t fxParams[] = { DistAmount, DistTone, DistMix, ChorusDepth, ChorusRate, ChorusWidth, ChorusDelay, ChorusFeedback, ChorusMix };
constexpr const char* fxLabels[] = { "Amount", "Tone", "Mix", "Depth", "Rate", "Width", "Delay", "Feedback", "Mix" };
NSRect fxToggle(int index) { return NSMakeRect(index ? 1182 : 558, 150, 46, 26); }
NSRect fxSlider(int index) {
    if (index < 3) return NSMakeRect(52, 310 + index * 100, 548, 26);
    int i = index - 3; return NSMakeRect(676 + (i % 2) * 298, 310 + (i / 2) * 100, 254, 26);
}
NSRect loadButton() { return NSMakeRect(1080, 37, 172, 40); }
constexpr uint32_t sliderParams[] = { Tune, FadeIn, FadeOut, Attack, Release };
NSRect sliderRow(int index) {
    const NSRect rows[] = {NSMakeRect(968, 194, 284, 26), NSMakeRect(125, 660, 169, 26), NSMakeRect(125, 701, 169, 26), NSMakeRect(518, 660, 169, 26), NSMakeRect(518, 701, 169, 26)};
    return rows[index];
}
NSRect speedButton() { return NSMakeRect(1206, 338, 46, 26); }
NSRect outputKnob() { return NSMakeRect(819, 650, 80, 76); }
NSRect rateSlider() { return NSMakeRect(968, 424, 284, 26); }
NSRect modeButton(int index) { return NSMakeRect(28 + 884.0 / 5 * index, 541, 884.0 / 5, 38); }
NSRect zoomButton(int index) { return NSMakeRect(718 + index * 62, 495, index == 2 ? 70 : 52, 32); }
NSRect octaveButton(int index) { return NSMakeRect(28 + index * 44, 782, 43, 32); }
NSRect loopTag(double x, double otherX, bool end) {
    double left = std::clamp(x - 14, detail().origin.x, NSMaxX(detail()) - 28);
    double otherLeft = std::clamp(otherX - 14, detail().origin.x, NSMaxX(detail()) - 28);
    double offset = end && std::abs(left - otherLeft) < 32 ? 40 : 10;
    return NSMakeRect(left, detail().origin.y + offset, 28, 24);
}
void drawSlider(NSRect r, double value, bool enabled = true) {
    const double y = NSMidY(r);
    box(NSMakeRect(r.origin.x, y - 2, r.size.width, 4), 0x515155, 2);
    if (enabled) box(NSMakeRect(r.origin.x, y - 2, std::max(2.0, r.size.width * value), 4), 0x0a84ff, 2);
    auto knob = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(r.origin.x + r.size.width * value - 8, y - 8, 16, 16)];
    [colour(enabled ? 0xe7e7e9 : 0x77777b) setFill]; [knob fill];
}
void valuePill(NSString* value, NSRect rect) {
    box(rect, 0x29292c, 8, 0x444448); label(value, NSInsetRect(rect, 4, 5), 16, 0xeeeeF2, false, NSTextAlignmentCenter);
}
NSTextField* numberField(NSRect rect, NSInteger tag, id target, SEL action) {
    auto field = [[NSTextField alloc] initWithFrame:rect];
    field.tag = tag; field.target = target; field.action = action;
    field.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    field.alignment = NSTextAlignmentCenter; field.bezelStyle = NSTextFieldRoundedBezel;
    field.backgroundColor = colour(0x29292c); field.textColor = colour(0xededf0); field.focusRingType = NSFocusRingTypeNone;
    return field;
}
void drawKnob(double value) {
    constexpr double pi = 3.14159265358979323846;
    NSPoint centre = NSMakePoint(858, 688);
    for (int pass = 0; pass < 2; ++pass) {
        auto arc = [NSBezierPath bezierPath]; arc.lineWidth = 3; arc.lineCapStyle = NSLineCapStyleRound;
        double end = pass ? value : 1;
        for (int i = 0; i <= 80; ++i) {
            double angle = (135 + 270 * end * i / 80) * pi / 180;
            auto point = NSMakePoint(centre.x + 29 * std::cos(angle), centre.y + 29 * std::sin(angle));
            if (i == 0) [arc moveToPoint:point]; else [arc lineToPoint:point];
        }
        [colour(pass ? 0x0a84ff : 0x515155) setStroke]; [arc stroke];
    }
    auto disk = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(835, 665, 46, 46)];
    [colour(0x343437) setFill]; [disk fill]; [colour(0x55555a) setStroke]; [disk stroke];
    double angle = (135 + 270 * value) * pi / 180;
    line(centre.x + 12 * std::cos(angle), centre.y + 12 * std::sin(angle), centre.x + 21 * std::cos(angle), centre.y + 21 * std::sin(angle), 0xe7e7e9, 2.5);
}
NSRect keyRect(int pitch, int base) {
    auto r = keyboard(); double w = r.size.width / 15;
    int whites = 0; for (int p = base; p < pitch; ++p) if (!isBlack(p)) ++whites;
    if (isBlack(pitch)) return NSMakeRect(r.origin.x + whites * w - w * .32, r.origin.y, w * .64, r.size.height * .62);
    return NSMakeRect(r.origin.x + whites * w, r.origin.y, w - 1, r.size.height);
}
int hitKey(NSPoint p, int base) {
    if (!NSPointInRect(p, keyboard())) return -1;
    for (int n = base; n <= base + 24; ++n) if (isBlack(n) && NSPointInRect(p, keyRect(n, base))) return n;
    for (int n = base; n <= base + 24; ++n) if (!isBlack(n) && NSPointInRect(p, keyRect(n, base))) return n;
    return -1;
}
bool hasKeyboardModifier(NSEvent* event) {
    return (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) != 0;
}
int keyboardPitch(NSEvent* event) {
    if (hasKeyboardModifier(event)) return -1;
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString;
    if (chars.length != 1) return -1;
    NSRange match = [@"awsedftgyhujkolp;" rangeOfString:chars];
    return match.location == NSNotFound ? -1 : 60 + static_cast<int>(match.location);
}
}

@implementation HLView {
    std::shared_ptr<Model> _model;
    std::function<void(uint32_t)> _begin, _end;
    std::function<void(uint32_t, double)> _change;
    std::function<void()> _dirty;
    NSTimer* _timer;
    NSPopUpButton* _lengthMenu;
    NSPopUpButton* _rootMenu;
    NSPopUpButton* _distTypeMenu;
    NSSegmentedControl* _syncControl;
    NSTextField* _tempoField;
    NSArray<NSTextField*>* _regionFields;
    double _viewStart, _viewLength, _anchor, _panStart, _loopStart, _loopEnd, _knobStart, _handleOffset;
    int _drag, _slider, _mouseNote, _keyboardBase, _lastSyncLength;
    bool _dropHover, _detached, _hosted, _fxTab;
    int _fxSlider;
    std::array<bool, 128> _held;
    // Match releases by physical key: characters/modifiers may change while held.
    std::array<int, 128> _keyboardNotes;
}
- (instancetype)initWithModel:(std::shared_ptr<Model>)model {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, editorWidth, editorHeight)])) {
        _model = std::move(model); _viewLength = 1; _mouseNote = -1; _keyboardBase = 48; _lastSyncLength = 3;
        _drag = 0; _slider = -1; _held.fill(false); _keyboardNotes.fill(-1);
        self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        self.toolTip = @"Pinch/scroll to zoom. Drag inside the loop to move it. Click outside or drag S/E to change its bounds. Shift-drag to pan. Double-click to fit.";
        [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
        [self setAccessibilityLabel:@"Essential Sampler sample editor"];
        _lengthMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(1148, 472, 104, 32) pullsDown:NO];
        for (int i = 1; i < lengthCount; ++i) [_lengthMenu addItemWithTitle:[NSString stringWithUTF8String:lengthNames[i]]];
        _lengthMenu.target = self; _lengthMenu.action = @selector(changeSyncLength:); _lengthMenu.tag = SyncLength;
        _lengthMenu.font = [NSFont systemFontOfSize:14]; _lengthMenu.toolTip = @"Fit the selected region to a musical length. Bars follow the host time signature; fractions are note values.";
        [self addSubview:_lengthMenu];
        _syncControl = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(968, 472, 158, 32)];
        _syncControl.segmentCount = 2; [_syncControl setLabel:@"Free" forSegment:0]; [_syncControl setLabel:@"Sync" forSegment:1];
        _syncControl.segmentStyle = NSSegmentStyleRounded; _syncControl.font = [NSFont systemFontOfSize:14];
        _syncControl.tag = 1002; _syncControl.target = self; _syncControl.action = @selector(changeSyncMode:); [self addSubview:_syncControl];
        _rootMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(1134, 242, 118, 32) pullsDown:NO];
        for (int note = 0; note < 128; ++note) [_rootMenu addItemWithTitle:valueText(Root, normalized(Root, note))];
        _rootMenu.font = [NSFont systemFontOfSize:14]; _rootMenu.tag = Root; _rootMenu.target = self; _rootMenu.action = @selector(changeRoot:); [self addSubview:_rootMenu];
        _tempoField = numberField(NSMakeRect(1153, 526, 99, 28), Tempo, self, @selector(changeTempo:));
        _tempoField.toolTip = @"Tempo from the DAW. Without host tempo, enter a fallback BPM (20–400).";
        [self addSubview:_tempoField];
        _regionFields = @[numberField(NSMakeRect(76, 496, 102, 30), Start, self, @selector(changeRegion:)), numberField(NSMakeRect(236, 496, 102, 30), End, self, @selector(changeRegion:)), numberField(NSMakeRect(416, 496, 102, 30), 1001, self, @selector(changeRegion:))];
        for (NSTextField* field in _regionFields) { field.toolTip = @"Time in seconds. Type a value and press Return."; [self addSubview:field]; }
        _distTypeMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(410, 211, 194, 32) pullsDown:NO];
        for (auto name : distortionNames) [_distTypeMenu addItemWithTitle:[NSString stringWithUTF8String:name]];
        _distTypeMenu.font = [NSFont systemFontOfSize:14]; _distTypeMenu.tag = DistType;
        _distTypeMenu.target = self; _distTypeMenu.action = @selector(changeDistType:); _distTypeMenu.hidden = YES;
        [self addSubview:_distTypeMenu];
        [self refreshTimingControls];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(focusLost:) name:NSApplicationDidResignActiveNotification object:NSApp];
        __weak HLView* weak = self;
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer*) { [weak refreshTimingControls]; [weak setNeedsDisplay:YES]; }];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return !_hosted; }
- (void)setHosted:(BOOL)hosted {
    _hosted = hosted;
    _distTypeMenu.cell.refusesFirstResponder = hosted;
    _rootMenu.cell.refusesFirstResponder = hosted;
    _lengthMenu.cell.refusesFirstResponder = hosted;
    _syncControl.cell.refusesFirstResponder = hosted;
}
- (void)releaseEditorFocus {
    if (!_hosted) return;
    NSResponder* responder = self.window.firstResponder;
    BOOL owned = responder == self;
    if ([responder isKindOfClass:NSView.class]) owned |= [(NSView*)responder isDescendantOf:self];
    // AppKit's shared field editor can live outside this view hierarchy.
    if ([responder isKindOfClass:NSTextView.class]) {
        id delegate = [(NSTextView*)responder delegate];
        owned |= [delegate isKindOfClass:NSView.class] && [(NSView*)delegate isDescendantOf:self];
    }
    if (owned) {
        NSView* target = self.superview;
        while (target && !target.acceptsFirstResponder) target = target.superview;
        [self.window makeFirstResponder:target];
    }
}
- (BOOL)resignFirstResponder { [self stopNotes]; [self finishGesture]; return YES; }
- (void)viewWillMoveToWindow:(NSWindow*)window {
    auto center = [NSNotificationCenter defaultCenter];
    if (self.window) [center removeObserver:self name:NSWindowDidResignKeyNotification object:self.window];
    if (window && !_detached) [center addObserver:self selector:@selector(focusLost:) name:NSWindowDidResignKeyNotification object:window];
    [super viewWillMoveToWindow:window];
}
- (void)viewDidMoveToWindow { if (!self.window) [self stopNotes]; }
- (void)focusLost:(NSNotification*)notification { (void)notification; [self stopNotes]; [self finishGesture]; }
- (void)setBeginEdit:(std::function<void(uint32_t)>)begin change:(std::function<void(uint32_t, double)>)change end:(std::function<void(uint32_t)>)end dirty:(std::function<void()>)dirty {
    _begin = std::move(begin); _change = std::move(change); _end = std::move(end); _dirty = std::move(dirty);
}
- (void)detach {
    if (_detached) return;
    _detached = true; [self finishGesture]; [self stopNotes]; [_timer invalidate]; _timer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _begin = {}; _end = {}; _change = {}; _dirty = {};
}
- (void)dealloc { [_timer invalidate]; [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)stopNotes {
    if (!_model) return;
    for (int n = 0; n < 128; ++n) if (_held[n]) { _model->preview(n, false); _held[n] = false; }
    _keyboardNotes.fill(-1);
    _mouseNote = -1;
    _model->stopPreviewNotes();
}
- (void)stopKeyboardNotes {
    for (auto& note : _keyboardNotes) if (note >= 0) {
        _model->preview(note, false); _held[note] = false; note = -1;
    }
}
- (void)edit:(uint32_t)id value:(double)value {
    value = norm(value);
    if (id == Root || id == ModeId || id == KeepSpeed || id == SyncLength || id == DistType || id == DistEnabled || id == ChorusEnabled) value = normalized(id, plain(id, value));
    _model->params[id].store(value);
    if (_change) _change(id, value);
    [self setNeedsDisplay:YES];
}
- (void)singleEdit:(uint32_t)id value:(double)value {
    if (_begin) _begin(id); [self edit:id value:value]; if (_end) _end(id);
}
- (void)refreshTimingControls {
    if (_detached) return;
    [_distTypeMenu selectItemAtIndex:static_cast<int>(plain(DistType, _model->params[DistType]))];
    int selected = static_cast<int>(plain(SyncLength, _model->params[SyncLength].load()));
    if (selected > 0) _lastSyncLength = selected;
    if (_lengthMenu.indexOfSelectedItem != _lastSyncLength - 1) [_lengthMenu selectItemAtIndex:_lastSyncLength - 1];
    _lengthMenu.enabled = selected > 0; _syncControl.selectedSegment = selected > 0 ? 1 : 0;
    int root = static_cast<int>(plain(Root, _model->params[Root].load()));
    if (_rootMenu.indexOfSelectedItem != root) [_rootMenu selectItemAtIndex:root];
    bool host = _model->hostTempoValid.load();
    _tempoField.enabled = !host;
    if (host || !_tempoField.currentEditor) _tempoField.stringValue = [NSString stringWithFormat:@"%.1f", _model->settings().tempo];
    [self refreshRegionFields:NO];
}
- (void)changeSyncLength:(NSPopUpButton*)sender {
    _lastSyncLength = static_cast<int>(sender.indexOfSelectedItem) + 1;
    [self singleEdit:SyncLength value:normalized(SyncLength, _lastSyncLength)];
    [self refreshTimingControls];
    [self releaseEditorFocus];
}
- (void)changeSyncMode:(NSSegmentedControl*)sender {
    [self singleEdit:SyncLength value:normalized(SyncLength, sender.selectedSegment == 0 ? 0 : _lastSyncLength)];
    [self refreshTimingControls];
    [self releaseEditorFocus];
}
- (void)changeDistType:(NSPopUpButton*)sender {
    [self singleEdit:DistType value:normalized(DistType, sender.indexOfSelectedItem)];
    [self releaseEditorFocus];
}
- (void)showFx:(BOOL)enabled {
    [self releaseEditorFocus]; [self finishGesture]; _fxTab = enabled;
    for (NSView* control in self.subviews) control.hidden = control == _distTypeMenu ? !enabled : enabled;
    [self setNeedsDisplay:YES];
}
- (void)drawFx {
    box(NSMakeRect(28, 126, 600, 453), 0x202023, 14, 0x37373d);
    box(NSMakeRect(652, 126, 600, 453), 0x202023, 14, 0x37373d);
    label(@"Distortion", NSMakeRect(52, 148, 360, 30), 23, 0xf2f2f5, true);
    label(@"Chorus", NSMakeRect(676, 148, 360, 30), 23, 0xf2f2f5, true);
    label(@"Harmonics, texture and colour", NSMakeRect(52, 184, 480, 22), 14, 0xa3a3aa);
    label(@"Movement and stereo space", NSMakeRect(676, 184, 480, 22), 14, 0xa3a3aa);
    label(@"Type", NSMakeRect(52, 216, 130, 24), 16, 0xe0e0e5);
    label(@"Stereo modulated delay", NSMakeRect(676, 218, 500, 20), 13, 0x85858f);
    for (int i=0; i<2; ++i) {
        bool on = _model->params[i ? ChorusEnabled : DistEnabled] >= .5;
        auto t=fxToggle(i); box(t,on ? 0x0a84ff : 0x4c4c51,13);
        box(NSMakeRect(t.origin.x+(on ? 22 : 3),t.origin.y+3,20,20),0xf5f5f7,10);
    }
    for (int i=0; i<9; ++i) {
        auto r=fxSlider(i); auto id=fxParams[i]; double v=plain(id,_model->params[id]);
        label([NSString stringWithUTF8String:fxLabels[i]],NSMakeRect(r.origin.x,r.origin.y-39,r.size.width-100,24),16,0xe0e0e5);
        NSString* value = id == ChorusRate ? [NSString stringWithFormat:@"%.2f Hz",v] : id == ChorusDelay ? [NSString stringWithFormat:@"%.1f ms",v] : [NSString stringWithFormat:@"%.0f %%",v];
        valuePill(value,NSMakeRect(NSMaxX(r)-94,r.origin.y-44,94,32));
        drawSlider(r,_model->params[id]);
    }
    label(@"Dark",NSMakeRect(52,442,120,18),11,0x85858f);
    label(@"Bright",NSMakeRect(480,442,120,18),11,0x85858f,false,NSTextAlignmentRight);
    label(@"Double-click a slider to reset",NSMakeRect(52,551,548,18),11,0x85858f);
    label(@"Width controls the wet signal",NSMakeRect(676,551,548,18),11,0x85858f);
}
- (void)changeRoot:(NSPopUpButton*)sender {
    [self singleEdit:Root value:normalized(Root, sender.indexOfSelectedItem)];
    [self releaseEditorFocus];
}
- (void)refreshRegionFields:(BOOL)force {
    auto sample = _model->samples.snapshot(); double seconds = sample ? sample->frames() / sample->rate : 0;
    double start = _model->params[Start].load(), end = _model->params[End].load();
    double values[] = {start * seconds, end * seconds, std::max(0.0, end - start) * seconds};
    for (int i = 0; i < 3; ++i) {
        _regionFields[i].enabled = seconds > 0;
        if (force || !_regionFields[i].currentEditor) _regionFields[i].stringValue = [NSString stringWithFormat:@"%.3f s", values[i]];
    }
}
- (void)changeRegion:(NSTextField*)sender {
    auto sample = _model->samples.snapshot();
    if (!sample || sample->frames() < 2) { [self refreshRegionFields:YES]; [self releaseEditorFocus]; return; }
    auto input = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([input hasSuffix:@"s"]) input = [input substringToIndex:input.length - 1];
    double seconds = 0; auto scanner = [NSScanner scannerWithString:input];
    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !std::isfinite(seconds)) { [self refreshRegionFields:YES]; [self releaseEditorFocus]; return; }
    double gap = 2.0 / sample->frames(), value = seconds / (sample->frames() / sample->rate);
    double start = std::clamp(norm(_model->params[Start].load()), 0.0, 1 - gap);
    double end = std::clamp(norm(_model->params[End].load()), start + gap, 1.0);
    if (sender.tag == Start) start = std::clamp(value, 0.0, end - gap);
    else if (sender.tag == End) end = std::clamp(value, start + gap, 1.0);
    else end = std::clamp(start + value, start + gap, 1.0);
    [self singleEdit:Start value:start]; [self singleEdit:End value:end];
    [self refreshRegionFields:YES]; [self releaseEditorFocus];
}
- (void)changeTempo:(NSTextField*)sender {
    if (!_model->hostTempoValid.load()) {
        double bpm = 0; auto scanner = [NSScanner scannerWithString:sender.stringValue];
        if ([scanner scanDouble:&bpm] && scanner.isAtEnd && std::isfinite(bpm)) [self singleEdit:Tempo value:normalized(Tempo, bpm)];
    }
    sender.stringValue = [NSString stringWithFormat:@"%.1f", _model->settings().tempo]; [self releaseEditorFocus];
}
- (double)timeAt:(double)x {
    auto r = detail(); return norm(_viewStart + (x - r.origin.x) / r.size.width * _viewLength);
}
- (void)zoom:(double)factor at:(double)x {
    auto s = _model->samples.snapshot(); double minimum = s ? std::min(1.0, 32.0 / s->frames()) : .001;
    double anchor = std::clamp((x - detail().origin.x) / detail().size.width, 0.0, 1.0);
    double length = std::clamp(_viewLength / std::max(.01, factor), minimum, 1.0);
    _viewStart = std::clamp(_viewStart + anchor * (_viewLength - length), 0.0, 1 - length);
    _viewLength = length; [self setNeedsDisplay:YES];
}
- (void)drawWave:(const Sample&)s rect:(NSRect)rect from:(double)start length:(double)length tint:(unsigned)tint {
    [NSGraphicsContext saveGraphicsState]; NSRectClip(rect);
    double mid = NSMidY(rect), amp = rect.size.height * .44;
    auto p = [NSBezierPath bezierPath]; p.lineWidth = 1;
    for (int x = 0; x < static_cast<int>(rect.size.width); ++x) {
        auto a = static_cast<size_t>(std::max(0.0, (start + x / rect.size.width * length) * s.frames()));
        auto b = static_cast<size_t>(std::max(0.0, (start + (x + 1) / rect.size.width * length) * s.frames()));
        auto peak = s.peak(a, b);
        [p moveToPoint:NSMakePoint(rect.origin.x + x + .5, mid - peak.hi * amp)];
        [p lineToPoint:NSMakePoint(rect.origin.x + x + .5, mid - peak.lo * amp + .35)];
    }
    [colour(tint) setStroke]; [p stroke];
    [NSGraphicsContext restoreGraphicsState];
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    auto background = [[NSGradient alloc] initWithStartingColor:colour(0x1d1d1f) endingColor:colour(0x18181a)];
    [background drawInRect:self.bounds angle:90];
    auto sample = _model->samples.snapshot();
    label(@"Essential Sampler", NSMakeRect(28, 30, 260, 37), 26, 0xf2f2f5, true);
    for (int i=0; i<2; ++i) {
        auto r=tabButton(i); bool active = i == (_fxTab ? 1 : 0);
        if (active) box(r,0x38383d,7);
        label(i ? @"FX" : @"Sampler",NSInsetRect(r,0,5),13,active ? 0xf2f2f5 : 0x92929c,active,NSTextAlignmentCenter);
    }
    NSString* name = sample ? [NSString stringWithUTF8String:sample->name.c_str()] : @"Load your first sample";
    label(name ?: @"Audio sample", NSMakeRect(300, 32, 650, 30), 20, 0xf2f2f5, true, NSTextAlignmentCenter);
    NSString* info = sample ? [NSString stringWithFormat:@"Stereo  ·  %.0f kHz  ·  %.3f s", sample->rate / 1000, sample->frames() / sample->rate] : @"WAV  ·  AIFF  ·  FLAC";
    label(info, NSMakeRect(300, 65, 650, 23), 14, 0xa3a3aa, false, NSTextAlignmentCenter);
    box(loadButton(), 0x29292c, 11, 0x454549);
    label(_model->loading.load() ? @"Loading…" : @"＋  Load sample", NSInsetRect(loadButton(), 5, 8), 17, 0xededf1, false, NSTextAlignmentCenter);
    if (_fxTab) [self drawFx]; else {
    auto ov = overview(), dt = detail();
    double loopStart = _model->params[Start].load(), loopEnd = _model->params[End].load();
    box(ov, 0x202023, 8, 0x3b3b40);
    if (sample) [self drawWave:*sample rect:NSInsetRect(ov, 4, 4) from:0 length:1 tint:0x77777e];
    [NSGraphicsContext saveGraphicsState]; NSRectClip(NSInsetRect(ov, 1, 1));
    [colour(0x0a84ff, .16) setFill]; NSRectFillUsingOperation(NSMakeRect(ov.origin.x + loopStart * ov.size.width, ov.origin.y, (loopEnd - loopStart) * ov.size.width, ov.size.height), NSCompositingOperationSourceOver);
    if (_viewLength < .999) {
        auto visible = NSMakeRect(ov.origin.x + _viewStart * ov.size.width, ov.origin.y + .5, _viewLength * ov.size.width, ov.size.height - 1);
        [colour(0xbabac2, .5) setStroke]; [NSBezierPath strokeRect:NSInsetRect(visible, .5, .5)];
    }
    [NSGraphicsContext restoreGraphicsState];
    line(dt.origin.x, dt.origin.y, NSMaxX(dt), dt.origin.y, 0x55555b);
    for (int i = 0; i <= 32; ++i) {
        double x = dt.origin.x + dt.size.width * i / 32;
        line(x, dt.origin.y - (i % 4 == 0 ? 9 : 5), x, dt.origin.y, 0x55555b);
        if (i % 4 != 0) continue;
        line(x, dt.origin.y, x, NSMaxY(dt), 0x353539);
        if (sample) {
            double t = (_viewStart + i / 32.0 * _viewLength) * sample->frames() / sample->rate;
            label([NSString stringWithFormat:@"%.3f s", t], NSMakeRect(std::clamp(x - 45, dt.origin.x, NSMaxX(dt) - 90), 189, 90, 21), 12, 0xb7b7bf, false, NSTextAlignmentCenter);
        }
    }
    line(dt.origin.x, NSMidY(dt), NSMaxX(dt), NSMidY(dt), 0x414145);
    double startX = dt.origin.x + (loopStart - _viewStart) / _viewLength * dt.size.width;
    double endX = dt.origin.x + (loopEnd - _viewStart) / _viewLength * dt.size.width;
    [NSGraphicsContext saveGraphicsState]; NSRectClip(dt);
    auto selected = NSMakeRect(startX, dt.origin.y, std::max(0.0, endX - startX), dt.size.height);
    [colour(0x0a84ff, .12) setFill]; NSRectFillUsingOperation(selected, NSCompositingOperationSourceOver);
    if (sample) {
        [self drawWave:*sample rect:dt from:_viewStart length:_viewLength tint:0x77777e];
        [NSGraphicsContext saveGraphicsState]; NSRectClip(selected);
        [self drawWave:*sample rect:dt from:_viewStart length:_viewLength tint:0x0a84ff];
        [NSGraphicsContext restoreGraphicsState];
        for (int side = 0; side < 2; ++side) {
            double duration = std::min(plain(side ? FadeOut : FadeIn, _model->params[side ? FadeOut : FadeIn].load()) * .001 * sample->rate, std::max(0.0, (loopEnd - loopStart) * sample->frames() - 1) * .5);
            double width = duration / sample->frames() / _viewLength * dt.size.width;
            double edge = side ? endX : startX, inner = side ? endX - width : startX + width;
            line(edge, NSMidY(dt), inner, dt.origin.y, 0x496c91);
            line(edge, NSMidY(dt), inner, NSMaxY(dt), 0x496c91);
        }
    }
    double pos = _model->playhead.load();
    if (pos >= 0) { double x = dt.origin.x + (pos - _viewStart) / _viewLength * dt.size.width; line(x, dt.origin.y, x, NSMaxY(dt), 0xf2f2f5, 1.5); }
    for (int side = 0; side < 2; ++side) {
        double x = side ? endX : startX;
        line(x, dt.origin.y, x, NSMaxY(dt), 0x0a84ff, 2);
        if (x >= dt.origin.x && x <= NSMaxX(dt)) {
            auto tag = loopTag(x, side ? startX : endX, side != 0); box(tag, 0x0a84ff, 6);
            label(side ? @"E" : @"S", NSInsetRect(tag, 0, 3), 14, 0xffffff, true, NSTextAlignmentCenter);
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    if (!sample || _dropHover) {
        box(NSMakeRect(250, 304, 440, 82), 0x252528, 12, 0x5d82ac);
        label(@"Drop a sample here", NSMakeRect(270, 319, 400, 28), 22, 0xf2f2f5, false, NSTextAlignmentCenter);
        label(@"WAV · AIFF · FLAC", NSMakeRect(270, 353, 400, 20), 13, 0xa3a3aa, false, NSTextAlignmentCenter);
    }
    label(@"Start", NSMakeRect(28, 502, 46, 20), 15, 0xd7d7dc);
    label(@"End", NSMakeRect(196, 502, 38, 20), 15, 0xd7d7dc);
    label(@"Length", NSMakeRect(356, 502, 58, 20), 15, 0xd7d7dc);
    label([NSString stringWithFormat:@"%.1f× zoom", 1 / _viewLength], NSMakeRect(555, 503, 137, 19), 12, 0x8b8b94, false, NSTextAlignmentRight);
    NSArray* zoom = @[@"−", @"+", @"Fit"];
    for (int i = 0; i < 3; ++i) { auto r = zoomButton(i); box(r, 0x29292c, 8, 0x424247); label(zoom[i], NSInsetRect(r, 0, 5), 16, 0xe2e2e7, false, NSTextAlignmentCenter); }
    box(NSMakeRect(28, 541, 884, 38), 0x29292c, 10, 0x36363b);
    int mode = static_cast<int>(plain(ModeId, _model->params[ModeId].load()));
    for (int i = 0; i < 5; ++i) {
        auto r = modeButton(i); bool active = i == mode;
        if (active) box(NSInsetRect(r, 3, 3), 0x505055, 8);
        label([NSString stringWithUTF8String:modeNames[i]], NSInsetRect(r, 0, 9), 14, active ? 0xf5f5f7 : 0xb6b6bf, active, NSTextAlignmentCenter);
    }
    line(940, 104, 940, 581, 0x444449);
    label(@"Pitch", NSMakeRect(968, 115, 180, 29), 22, 0xf2f2f5, true);
    label(@"Tune", NSMakeRect(968, 161, 110, 23), 16, 0xe0e0e5);
    valuePill(valueText(Tune, _model->params[Tune].load()), NSMakeRect(1144, 155, 108, 32));
    drawSlider(sliderRow(0), _model->params[Tune].load());
    label(@"Root note", NSMakeRect(968, 247, 130, 23), 16, 0xe0e0e5);
    line(968, 289, 1252, 289, 0x3a3a3f);
    label(@"Time", NSMakeRect(968, 304, 180, 29), 22, 0xf2f2f5, true);
    auto timing = _model->settings(); bool synced = timing.syncLength > 0;
    label(@"Keep duration", NSMakeRect(968, 340, 220, 24), 16, 0xe0e0e5);
    bool locked = synced || timing.keepSpeed;
    auto toggle = speedButton(); box(toggle, locked ? 0x0a84ff : 0x4c4c51, 13);
    box(NSMakeRect(toggle.origin.x + (locked ? 22 : 3), toggle.origin.y + 3, 20, 20), 0xf5f5f7, 10);
    label(@"Speed", NSMakeRect(968, 390, 110, 23), 16, 0xe0e0e5);
    double rate = sample ? playbackSpeed(timing, sample->frames(), sample->rate) : timing.speed;
    valuePill([NSString stringWithFormat:@"%.2f×", rate], NSMakeRect(1144, 384, 108, 32));
    drawSlider(rateSlider(), _model->params[PlaybackRate].load(), !synced);
    label(_model->hostTempoValid.load() ? @"Host tempo" : @"Tempo · BPM", NSMakeRect(968, 532, 175, 20), 13, 0xa3a3aa);
    label(synced ? [NSString stringWithFormat:@"%d/%d · duration follows the project", _model->timeSigNumerator.load(), _model->timeSigDenominator.load()] : @"Pitch stays independent of speed", NSMakeRect(968, 563, 284, 16), 11, 0x85858f);
    }
    line(28, 606, 1252, 606, 0x414146);
    if (!_fxTab) {
    label(@"Loop fades", NSMakeRect(28, 623, 300, 28), 21, 0xf0f0f3, true);
    label(@"Envelope", NSMakeRect(420, 623, 300, 28), 21, 0xf0f0f3, true);

    line(393, 627, 393, 725, 0x3d3d43); line(794, 627, 794, 725, 0x3d3d43);
    const char* titles[] = {"", "Fade in", "Fade out", "Attack", "Release"};
    for (int i = 1; i < 5; ++i) {
        auto r = sliderRow(i); auto param = sliderParams[i];
        double left = i < 3 ? 28 : 420, valueX = i < 3 ? 300 : 694;
        label([NSString stringWithUTF8String:titles[i]], NSMakeRect(left, r.origin.y + 3, 95, 22), 15, 0xd8d8df);
        drawSlider(r, _model->params[param].load());
        label([NSString stringWithFormat:@"%.0f ms", plain(param, _model->params[param].load())], NSMakeRect(valueX, r.origin.y + 3, 76, 22), 14, 0xd8d8df, false, NSTextAlignmentRight);
    }
    } else {
        label(@"Signal flow",NSMakeRect(28,623,300,28),21,0xf0f0f3,true);
        NSArray* names = @[@"Sampler",@"Distortion",@"Chorus"];
        for (int i=0;i<3;++i) {
            auto r=NSMakeRect(28+i*242,674,200,38); box(r,0x29292c,8,0x3d3d43);
            label(names[i],NSInsetRect(r,0,9),14,0xe2e2e7,false,NSTextAlignmentCenter);
            label(@"→",NSMakeRect(NSMaxX(r)+7,680,28,24),18,0x85858f,false,NSTextAlignmentCenter);
        }
        line(794,627,794,725,0x3d3d43);
    }
    label(@"Output", NSMakeRect(820, 623, 300, 28), 21, 0xf0f0f3, true);
    drawKnob(_model->params[Gain].load());
    label(valueText(Gain, _model->params[Gain].load()), NSMakeRect(909, 675, 115, 25), 18, 0xe8e8ed);
    float peak = _model->meter.load();
    double level = std::clamp((20.0 * std::log10(std::max(1.e-6f, peak)) + 60) / 60, 0.0, 1.0);
    for (int i = 0; i < 20; ++i) box(NSMakeRect(1046 + i * 10.3, 675, 7, 18), i < level * 20 ? (peak > 1 ? 0xff6962 : 0x0a84ff) : 0x3b3b40, 2);
    label(@"−60", NSMakeRect(1046, 700, 44, 17), 10, 0x85858f);
    label(@"0 dB", NSMakeRect(1206, 700, 46, 17), 10, 0x85858f, false, NSTextAlignmentRight);
    for (int pass = 0; pass < 2; ++pass) for (int n = _keyboardBase; n <= _keyboardBase + 24; ++n) if (isBlack(n) == (pass == 1)) {
        auto r = keyRect(n, _keyboardBase);
        box(r, _held[n] ? 0x2865a5 : pass ? 0x111113 : 0x45454a, pass ? 4 : 5, pass ? 0x08080a : 0x242428);
        if (n % 12 == 0) label([NSString stringWithFormat:@"C%d", n / 12 - 1], NSMakeRect(r.origin.x + 6, NSMaxY(r) - 23, r.size.width - 12, 20), 13, 0xddddE3);
    }
    for (int i = 0; i < 2; ++i) { auto r = octaveButton(i); box(r, 0x29292c, 8, 0x444449); label(i ? @"+" : @"−", NSInsetRect(r, 0, 4), 20, 0xe2e2e7, false, NSTextAlignmentCenter); }
    label(@"Octave", NSMakeRect(28, 756, 88, 18), 11, 0x85858f, false, NSTextAlignmentCenter);
    line(1115, 764, 1115, 818, 0x444449);
    label([NSString stringWithFormat:@"%d / 16 voices", _model->activeVoices.load()], NSMakeRect(1134, 784, 118, 22), 14, 0xa3a3aa, false, NSTextAlignmentCenter);
    auto status = _model->getStatus();
    label(status.empty() ? @"Essential Sampler  ·  0.6.2" : [NSString stringWithUTF8String:status.c_str()], NSMakeRect(28, 840, 1180, 16), 10, status.empty() ? 0x65656f : 0xffb58a);
}
- (void)openFile {
    NSOpenPanel* panel = [NSOpenPanel openPanel]; panel.canChooseDirectories = NO; panel.allowsMultipleSelection = NO;
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"wav"], [UTType typeWithFilenameExtension:@"aiff"], [UTType typeWithFilenameExtension:@"flac"]];
    panel.message = @"Load a mono or stereo sample";
    __weak HLView* weak = self;
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSModalResponseOK) [weak loadPath:panel.URL.path];
    }];
}
- (void)loadPath:(NSString*)path {
    if (_model->loading.exchange(true)) return;
    auto model = _model; std::string file = path.UTF8String; __weak HLView* weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        std::string error; auto sample = loadAudioFile(file, error);
        dispatch_async(dispatch_get_main_queue(), ^{
            HLView* view = weak;
            if (sample) {
                model->samples.publish(sample); model->panic.store(true); model->setStatus("");
                if (view && !view->_detached) {
                    [view singleEdit:Start value:0]; [view singleEdit:End value:1];
                    view->_viewStart = 0; view->_viewLength = 1; [view stopNotes];
                    if (view->_dirty) view->_dirty();
                }
            } else model->setStatus(error);
            model->loading.store(false); [view setNeedsDisplay:YES];
        });
    });
}
- (void)mouseDown:(NSEvent*)event {
    if (_hosted) [self releaseEditorFocus]; else [self.window makeFirstResponder:self];
    [self finishGesture];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, loadButton())) { [self openFile]; return; }
    for (int i = 0; i < 2; ++i) if (NSPointInRect(p, octaveButton(i))) {
        [self stopNotes]; _keyboardBase = std::clamp(_keyboardBase + (i ? 12 : -12), 0, 96); [self setNeedsDisplay:YES]; return;
    }
    if (NSPointInRect(p, outputKnob())) {
        if (event.clickCount == 2) { [self singleEdit:Gain value:defaults[Gain]]; return; }
        _drag = 8; _anchor = p.y; _knobStart = _model->params[Gain].load(); if (_begin) _begin(Gain); return;
    }
    int key = hitKey(p, _keyboardBase);
    if (key >= 0) { _drag = 6; _mouseNote = key; _held[key] = true; _model->preview(key, true); return; }
    for (int i=0;i<2;++i) if(NSPointInRect(p,tabButton(i))) { [self showFx:i == 1]; return; }
    if (_fxTab) {
        for(int i=0;i<2;++i) if(NSPointInRect(p,fxToggle(i))) {
            auto id=i ? ChorusEnabled : DistEnabled; [self singleEdit:id value:_model->params[id] >= .5 ? 0 : 1]; return;
        }
        for(int i=0;i<9;++i) if(NSPointInRect(p,fxSlider(i))) {
            auto id=fxParams[i];
            if(event.clickCount==2) { [self singleEdit:id value:defaults[id]]; return; }
            _drag=10; _fxSlider=i; if(_begin)_begin(id); [self mouseDragged:event]; return;
        }
        return;
    }
    if (NSPointInRect(p, speedButton())) {
        if (plain(SyncLength, _model->params[SyncLength].load()) == 0) [self singleEdit:KeepSpeed value:plain(KeepSpeed, _model->params[KeepSpeed].load()) > .5 ? 0 : 1];
        return;
    }
    if (NSPointInRect(p, rateSlider())) {
        if (plain(SyncLength, _model->params[SyncLength].load()) > 0) return;
        if (event.clickCount == 2) { [self singleEdit:PlaybackRate value:defaults[PlaybackRate]]; return; }
        _drag = 9; if (_begin) _begin(PlaybackRate); [self mouseDragged:event]; return;
    }
    for (int i = 0; i < 5; ++i) if (NSPointInRect(p, modeButton(i))) { [self singleEdit:ModeId value:i / 4.0]; return; }
    for (int i = 0; i < 3; ++i) if (NSPointInRect(p, zoomButton(i))) {
        if (i == 2) { _viewStart = 0; _viewLength = 1; [self setNeedsDisplay:YES]; }
        else [self zoom:i == 0 ? .5 : 2 at:NSMidX(detail())]; return;
    }
    for (int i = 0; i < 5; ++i) if (NSPointInRect(p, sliderRow(i))) {
        auto id = sliderParams[i];
        if (event.clickCount == 2) { [self singleEdit:id value:defaults[id]]; return; }
        _drag = 5; _slider = i; if (_begin) _begin(id); [self mouseDragged:event]; return;
    }
    if (NSPointInRect(p, overview())) { _drag = 4; [self mouseDragged:event]; return; }
    if (NSPointInRect(p, detail())) {
        if (event.clickCount == 2) { _viewStart = 0; _viewLength = 1; [self setNeedsDisplay:YES]; return; }
        if (event.modifierFlags & NSEventModifierFlagShift) { _drag = 7; _anchor = p.x; _panStart = _viewStart; return; }
        double startX = detail().origin.x + (_model->params[Start].load() - _viewStart) / _viewLength * detail().size.width;
        double endX = detail().origin.x + (_model->params[End].load() - _viewStart) / _viewLength * detail().size.width;
        _loopStart = norm(_model->params[Start].load()); _loopEnd = norm(_model->params[End].load());
        _handleOffset = 0;
        if (startX >= detail().origin.x && startX <= NSMaxX(detail()) && NSPointInRect(p, loopTag(startX, endX, false))) { _drag = 1; _handleOffset = [self timeAt:p.x] - _loopStart; }
        else if (endX >= detail().origin.x && endX <= NSMaxX(detail()) && NSPointInRect(p, loopTag(endX, startX, true))) { _drag = 2; _handleOffset = [self timeAt:p.x] - _loopEnd; }
        else if (p.x < startX) _drag = 1;
        else if (p.x > endX) _drag = 2;
        else { _drag = 3; _anchor = [self timeAt:p.x]; }
        if (_begin) { if (_drag != 2) _begin(Start); if (_drag != 1) _begin(End); }
        if (_drag == 1 || _drag == 2) [self mouseDragged:event];
    }
}
- (void)mouseDragged:(NSEvent*)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    auto sample = _model->samples.snapshot(); double minGap = sample ? 2.0 / sample->frames() : .0001;
    double t = [self timeAt:p.x];
    if (_drag == 1) [self edit:Start value:std::min(t - _handleOffset, std::max(0.0, _model->params[End].load() - minGap))];
    if (_drag == 2) [self edit:End value:std::max(t - _handleOffset, std::min(1.0, _model->params[Start].load() + minGap))];
    if (_drag == 3) {
        double delta = std::clamp(t - _anchor, -_loopStart, 1 - _loopEnd);
        [self edit:Start value:_loopStart + delta]; [self edit:End value:_loopEnd + delta];
    }
    if (_drag == 4) _viewStart = std::clamp((p.x - overview().origin.x) / overview().size.width - _viewLength * .5, 0.0, 1 - _viewLength);
    if (_drag == 5 && _slider >= 0) { auto r = sliderRow(_slider); [self edit:sliderParams[_slider] value:(p.x - r.origin.x) / r.size.width]; }
    if (_drag == 6) {
        int key = hitKey(p, _keyboardBase);
        if (key != _mouseNote) {
            if (_mouseNote >= 0) { _model->preview(_mouseNote, false); _held[_mouseNote] = false; }
            _mouseNote = key; if (key >= 0) { _model->preview(key, true); _held[key] = true; }
        }
    }
    if (_drag == 7) _viewStart = std::clamp(_panStart - (p.x - _anchor) / detail().size.width * _viewLength, 0.0, 1 - _viewLength);
    if (_drag == 8) [self edit:Gain value:_knobStart + (_anchor - p.y) / ((event.modifierFlags & NSEventModifierFlagShift) ? 1200 : 180)];
    if (_drag == 10) { auto r=fxSlider(_fxSlider); [self edit:fxParams[_fxSlider] value:(p.x-r.origin.x)/r.size.width]; }
    if (_drag == 9) [self edit:PlaybackRate value:(p.x - rateSlider().origin.x) / rateSlider().size.width];
    [self setNeedsDisplay:YES];
}
- (void)finishGesture {
    if (_end) {
        if (_drag == 1 || _drag == 3) _end(Start);
        if (_drag == 2 || _drag == 3) _end(End);
        if (_drag == 5 && _slider >= 0) _end(sliderParams[_slider]);
        if (_drag == 8) _end(Gain);
        if (_drag == 9) _end(PlaybackRate);
        if (_drag == 10) _end(fxParams[_fxSlider]);
    }
    _drag = 0; _slider = -1;
}
- (void)mouseUp:(NSEvent*)event {
    (void)event;
    if (_mouseNote >= 0) { _model->preview(_mouseNote, false); _held[_mouseNote] = false; _mouseNote = -1; }
    [self finishGesture]; [self setNeedsDisplay:YES];
}
- (void)scrollWheel:(NSEvent*)event {
    if (_fxTab) { [super scrollWheel:event]; return; }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, detail()) && !NSPointInRect(p, overview())) { [super scrollWheel:event]; return; }
    double dx = event.scrollingDeltaX, dy = event.scrollingDeltaY;
    if (event.modifierFlags & NSEventModifierFlagShift) { dx += dy; dy = 0; }
    if (std::abs(dx) > std::abs(dy)) _viewStart = std::clamp(_viewStart - dx / detail().size.width * _viewLength, 0.0, 1 - _viewLength);
    else [self zoom:std::exp(dy * (event.hasPreciseScrollingDeltas ? .012 : .16)) at:p.x];
    [self setNeedsDisplay:YES];
}
- (void)magnifyWithEvent:(NSEvent*)event {
    if (_fxTab) return;
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(p, detail()) || NSPointInRect(p, overview())) [self zoom:std::exp(event.magnification * 2) at:p.x];
}
- (void)keyDown:(NSEvent*)event {
    const auto key = event.keyCode;
    const int mapped = keyboardPitch(event);
    const int note = mapped < 0 ? -1 : mapped + _keyboardBase - 48;
    if (_hosted || _detached || note < 0 || key >= _keyboardNotes.size()) {
        [self.nextResponder keyDown:event]; return;
    }
    if (event.isARepeat) {
        if (_keyboardNotes[key] < 0) [self.nextResponder keyDown:event];
        return;
    }
    if (_keyboardNotes[key] < 0 && !_held[note]) {
        _keyboardNotes[key] = note; _held[note] = true; _model->preview(note, true);
    }
}
- (void)keyUp:(NSEvent*)event {
    const auto key = event.keyCode;
    bool owned = key < _keyboardNotes.size() && _keyboardNotes[key] >= 0;
    if (owned) {
        int note = _keyboardNotes[key]; _keyboardNotes[key] = -1;
        _held[note] = false; _model->preview(note, false);
    }
    if (!owned || hasKeyboardModifier(event)) [self.nextResponder keyUp:event];
}
- (void)flagsChanged:(NSEvent*)event {
    // A host shortcut can take over before keyUp reaches us. Release only the
    // computer-keyboard notes; mouse notes and incoming MIDI stay untouched.
    if (hasKeyboardModifier(event)) [self stopKeyboardNotes];
    [self.nextResponder flagsChanged:event];
}
- (BOOL)performKeyEquivalent:(NSEvent*)event {
    (void)event;
    return NO; // Let the host resolve shortcuts and menu commands.
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    _dropHover = YES; [self setNeedsDisplay:YES]; return NSDragOperationCopy;
}
- (void)draggingExited:(id<NSDraggingInfo>)sender { (void)sender; _dropHover = NO; [self setNeedsDisplay:YES]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    _dropHover = NO;
    NSArray<NSURL*>* files = [sender.draggingPasteboard readObjectsForClasses:@[[NSURL class]] options:@{NSPasteboardURLReadingFileURLsOnlyKey:@YES}];
    if (files.count) { [self loadPath:files.firstObject.path]; return YES; } return NO;
}
@end
