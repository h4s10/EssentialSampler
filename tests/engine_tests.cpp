#include "Engine.hpp"
#include "State.hpp"
#include "FFT.hpp"
#include <cassert>
#include <iostream>
#include <thread>
using namespace hasio;
static std::shared_ptr<Sample> ramp(size_t n = 8) {
    auto s = std::make_shared<Sample>(); s->name = "Test ramp";
    for (size_t i = 0; i < n; ++i) { s->left.push_back(float(i) / n); s->right.push_back(-float(i) / n); }
    s->buildPeaks(); return s;
}
static Settings config(Mode mode) {
    Settings s; s.mode = mode; s.attackMs = 0; s.releaseMs = 5; s.fadeInMs = s.fadeOutMs = 0; s.gainDb = 0; s.keepSpeed = false; return s;
}
static void equal(double a, double b, double tolerance = 1.e-5) {
    if (std::abs(a - b) > tolerance) { std::cerr << "Expected " << b << ", got " << a << '\n'; std::abort(); }
}
static void advance(Engine& e, int n) { float l, r; for (int i = 0; i < n; ++i) e.render(l, r); }
static double frequency(const std::vector<float>& samples, double rate) {
    constexpr size_t n = 32768; assert(samples.size() >= n + 8192);
    std::array<float, n> real{}, imaginary{};
    constexpr double pi = 3.14159265358979323846;
    for (size_t i = 0; i < n; ++i) real[i] = samples[8192 + i] * static_cast<float>(.5 - .5 * std::cos(2 * pi * i / n));
    FFT fft(n); fft.forward(real.data(), imaginary.data());
    auto mag = [&](int i) { return std::hypot(real[i], imaginary[i]); };
    int peak = 1; for (int i = 2; i < static_cast<int>(n / 2 - 1); ++i) if (mag(i) > mag(peak)) peak = i;
    double a = std::log(mag(peak - 1) + 1.e-12), b = std::log(mag(peak) + 1.e-12), c = std::log(mag(peak + 1) + 1.e-12);
    return (peak + .5 * (a - c) / (a - 2 * b + c)) * rate / n;
}
int main() {
    auto sample = ramp(); Engine e;
    auto start = [&](Mode mode, double rate = 48000) {
        e.configure(config(mode)); e.prepare(rate); e.setSample(sample.get()); e.noteOn(60, 1); advance(e, Engine::latencySamples());
    };
    float l, r;
    start(Mode::Forward);
    for (int i = 0; i < 40; ++i) { e.render(l, r); equal(l, float(i % 8) / 8); equal(r, -l); }
    start(Mode::Reverse);
    for (int i = 0; i < 40; ++i) { e.render(l, r); equal(l, float(7 - i % 8) / 8); }
    start(Mode::PingPong);
    const int expected[] = {0,1,2,3,4,5,6,7,6,5,4,3,2,1,0,1,2,3,4,5,6,7,6,5,4,3,2,1};
    for (int v : expected) { e.render(l, r); equal(l, float(v) / 8); }
    start(Mode::OneShot); e.noteOff(60); advance(e, 8);
    assert(e.activeCount() == 0); e.render(l, r); equal(l, 0);
    start(Mode::ReverseOneShot); e.noteOff(60); advance(e, 8); assert(e.activeCount() == 0);
    start(Mode::Forward); e.noteOff(60); advance(e, Engine::latencySamples() + 250); assert(e.activeCount() == 0);
    start(Mode::Forward, 96000);
    for (int i = 0; i < 12; ++i) { e.render(l, r); equal(l, float(i) / 16); }
    start(Mode::Forward); e.allNotesOff(); e.noteOn(72, 1); advance(e, Engine::latencySamples());
    for (int i = 0; i < 12; ++i) { e.render(l, r); equal(l, float((i * 2) % 8) / 8); }
    auto cfg = config(Mode::Forward); cfg.start = .25; cfg.end = .75;
    e.configure(cfg); e.prepare(48000); e.setSample(sample.get()); e.noteOn(60, 1); advance(e, Engine::latencySamples());
    for (int i = 0; i < 20; ++i) { e.render(l, r); equal(l, float(2 + i % 4) / 8); }
    e.allNotesOff(); for (int i = 0; i < 32; ++i) e.noteOn(40 + i, 1, i, 1);
    assert(e.activeCount() == 16); e.allNotesOff(); assert(e.activeCount() == 0);
    e.noteOn(60, 1, 100, 1); e.noteOn(60, 1, 101, 2); e.noteOff(60, 100, 1);
    advance(e, Engine::latencySamples() + 250); assert(e.activeCount() == 1);
    for (int mode = 0; mode < 5; ++mode) {
        cfg = config(static_cast<Mode>(mode)); cfg.start = .99; cfg.end = .1; cfg.root = 0; cfg.tune = 24; cfg.fadeInMs = cfg.fadeOutMs = 50;
        e.configure(cfg); e.prepare(8000); e.setSample(sample.get()); e.noteOn(127, 1);
        for (int i = 0; i < 6000; ++i) { e.render(l, r); assert(std::isfinite(l) && std::abs(l) < 2); }
    }
    // Fades attenuate the loop seam without shortening its period.
    e.setSample(nullptr); sample = ramp(1024);
    auto maxJump = [&](double fadeMs) {
        cfg = config(Mode::Forward); cfg.fadeInMs = cfg.fadeOutMs = fadeMs;
        e.configure(cfg); e.prepare(48000); e.setSample(sample.get()); e.noteOn(60, 1);
        advance(e, Engine::latencySamples());
        float previous = 0, jump = 0;
        for (int i = 0; i < 4096; ++i) { e.render(l, r); if (i) jump = std::max(jump, std::abs(l - previous)); previous = l; }
        equal(e.playhead(), 0); return jump;
    };
    assert(maxJump(0) > .9); assert(maxJump(5) < .02);
    // Exact output delay at unity, including short one-shots and sample tail.
    auto impulse = ramp(256); std::fill(impulse->left.begin(), impulse->left.end(), 0); impulse->left[10] = 1; impulse->right = impulse->left;
    e.configure(config(Mode::OneShot)); e.prepare(48000); e.setSample(impulse.get()); e.noteOn(60, 1);
    for (int i = 0; i < 256 + Engine::latencySamples(); ++i) { e.render(l, r); equal(l, i == 10 + Engine::latencySamples() ? 1 : 0); }
    assert(e.activeCount() == 0);
    // Measure the output frequency, not merely the internal pitch parameter.
    auto tone = ramp(96000); tone->rate = 48000;
    for (size_t i = 0; i < tone->frames(); ++i) tone->right[i] = tone->left[i] = static_cast<float>(.5 * std::sin(2 * 3.141592653589793 * 440 * i / tone->rate));
    for (auto test : std::array<std::array<double, 4>, 6>{{{60, 12, 1, 880}, {60, -12, 1, 220}, {60, 7, 1, 659.255}, {72, 0, 1, 880}, {72, -12, 0, 440}, {60, 12, 0, 880}}}) {
        cfg = config(Mode::OneShot); cfg.tune = test[1]; cfg.keepSpeed = test[2] > .5;
        e.configure(cfg); e.prepare(48000); e.setSample(tone.get()); e.noteOn(static_cast<int>(test[0]), 1);
        std::vector<float> audio; int transport = 0;
        while (e.activeCount()) {
            if (e.transportCount()) ++transport;
            e.render(l, r); audio.push_back(l); equal(l, r); assert(std::isfinite(l)); assert(audio.size() < 200000);
        }
        int expectedFrames = test[2] > .5 || test[0] == 60 ? 96000 : 48000;
        equal(transport, expectedFrames);
        auto measured = frequency(audio, 48000); equal(measured, test[3], 3.0);
        std::cout << "Pitch: " << measured << " Hz, transport " << transport << " frames\n";
    }
    // Tune automation and Keep speed changes must not rewind a running voice.
    cfg = config(Mode::Forward); cfg.keepSpeed = true;
    e.configure(cfg); e.prepare(44100); e.setSample(tone.get()); e.noteOn(72, 1); advance(e, 4410); equal(e.playhead(), .05, 1.e-6);
    cfg.tune = -7; e.configure(cfg); advance(e, 4410); equal(e.playhead(), .10, 1.e-6);
    cfg.keepSpeed = false; e.configure(cfg); advance(e, 4410); equal(e.playhead(), .20, 1.e-6);
    // Playback speed changes duration while the compensating pitch shift keeps the tone.
    auto longTone = ramp(192000);
    for (size_t i = 0; i < longTone->frames(); ++i) longTone->right[i] = longTone->left[i] = static_cast<float>(.5 * std::sin(2 * 3.141592653589793 * 440 * i / 48000));
    for (double speed : {.25, .5, 2., 4.}) {
        cfg = config(Mode::OneShot); cfg.keepSpeed = true; cfg.speed = speed;
        e.configure(cfg); e.prepare(48000); e.setSample(longTone.get()); e.noteOn(60, 1);
        std::vector<float> audio; int transport = 0;
        while (e.activeCount()) {
            if (e.transportCount()) ++transport;
            e.render(l, r); audio.push_back(l); assert(std::isfinite(l));
        }
        equal(transport, 192000 / speed, 1); double measured = frequency(audio, 48000); equal(measured, 440, 3);
        std::cout << "Speed " << speed << "x: " << measured << " Hz, transport " << transport << " frames\n";
    }
    // Note values are quarter-note based; bars follow time signature. Sync wins
    // over classic MIDI varispeed, so all pitches fit the requested duration.
    for (int length = 1; length < lengthCount; ++length) {
        cfg = config(Mode::OneShot); cfg.syncLength = length; cfg.tempo = 120; cfg.beatsPerBar = 3; cfg.keepSpeed = false;
        e.configure(cfg); e.prepare(48000); e.setSample(tone.get()); e.noteOn(72, 1);
        int transport = 0; while (e.transportCount()) { e.render(l, r); ++transport; assert(transport < 400000); }
        const double beats[] = {0, 12, 6, 3, 2, 1, .5, .25, .125};
        equal(transport, beats[length] * 24000, 1);
    }
    for (auto mode : {Mode::Forward, Mode::Reverse, Mode::PingPong}) {
        cfg = config(mode); cfg.syncLength = 3; cfg.tempo = 120; cfg.beatsPerBar = 3; cfg.start = .25; cfg.end = .75;
        e.configure(cfg); e.prepare(48000); e.setSample(tone.get()); e.noteOn(72, 1);
        double initial = e.playhead(); advance(e, 72000);
        double distance = std::abs(e.playhead() - initial);
        if (mode != Mode::PingPong) distance = std::min(distance, std::abs(.5 - distance));
        equal(distance, 0, 1.e-5); // either side of the same wrap point is equivalent
    }
    cfg = config(Mode::Forward); cfg.keepSpeed = true; cfg.speed = 1;
    e.configure(cfg); e.prepare(48000); e.setSample(tone.get()); e.noteOn(60, 1); advance(e, 4800); equal(e.playhead(), .05);
    cfg.speed = 2; cfg.tune = 7; e.configure(cfg); advance(e, 4800); equal(e.playhead(), .15);
    cfg.syncLength = 3; cfg.tempo = 60; e.configure(cfg); advance(e, 4800); equal(e.playhead(), .175);
    cfg.tempo = 120; e.configure(cfg); advance(e, 4800); equal(e.playhead(), .225);
    // Focus loss kills UI voices, including one-shots, without killing host MIDI
    // even when pitch, channel and note ID happen to be identical.
    for (auto mode : {Mode::Forward, Mode::OneShot}) {
        cfg = config(mode); e.configure(cfg); e.prepare(48000); e.setSample(tone.get());
        e.noteOn(60, 1, -1, 15); e.previewEvent({60, -1, 15, 1, true}); assert(e.activeCount() == 2);
        e.previewEvent({0, -1, 15, 0, false, true}); assert(e.activeCount() == 1);
        e.previewEvent({60, -1, 15, 1, true}); assert(e.activeCount() == 2); // focus regained, fresh key
    }
    Model model; model.samples.publish(sample); model.params[Root].store(normalized(Root, 48));
    model.params[FadeIn].store(normalized(FadeIn, 37)); model.params[FadeOut].store(normalized(FadeOut, 81));
    model.params[PlaybackRate].store(normalized(PlaybackRate, 2)); model.params[SyncLength].store(normalized(SyncLength, 3)); model.params[Tempo].store(normalized(Tempo, 140));
    model.params[DistEnabled]=1; model.params[DistType]=normalized(DistType,5);
    model.params[DistAmount]=.78; model.params[ChorusEnabled]=1;
    model.params[ChorusRate]=normalized(ChorusRate,2.1); model.params[ChorusFeedback]=normalized(ChorusFeedback,70);
    auto state = saveState(model); Model restored;
    assert(loadState(restored, state.data(), state.size())); assert(restored.samples.snapshot()->left == sample->left);
    equal(restored.params[Root].load(), model.params[Root].load()); equal(plain(FadeIn, restored.params[FadeIn].load()), 37); equal(plain(FadeOut, restored.params[FadeOut].load()), 81);
    equal(restored.settings().speed, 2); equal(restored.settings().syncLength, 3); equal(restored.settings().tempo, 140);
    restored.setHostTiming(96, 7, 8); equal(restored.settings().tempo, 96); equal(restored.settings().beatsPerBar, 3.5);
    restored.setHostTiming(NAN, -1, 0); equal(restored.settings().tempo, 140); equal(restored.settings().beatsPerBar, 4);
    assert(restored.settings().fx.distEnabled && restored.settings().fx.chorusEnabled);
    equal(restored.settings().fx.amount,.78); equal(restored.settings().fx.type,5);
    equal(restored.settings().fx.rate,2.1); equal(restored.settings().fx.feedback,.7);
    std::vector<uint8_t> v04(state.begin(),state.begin()+12+15*8); v04[8]=15;
    v04.insert(v04.end(),state.begin()+12+ParamCount*8,state.end());
    assert(loadState(restored,v04.data(),v04.size()));
    assert(!restored.settings().fx.distEnabled && !restored.settings().fx.chorusEnabled);
    equal(restored.settings().speed,2); equal(restored.settings().fx.rate,.35);
    std::vector<uint8_t> v02(state.begin(), state.begin() + 12 + 12 * 8); v02[8] = 12;
    v02.insert(v02.end(), state.begin() + 12 + ParamCount * 8, state.end());
    assert(loadState(restored, v02.data(), v02.size())); equal(restored.settings().speed, 1); equal(restored.settings().syncLength, 0); equal(restored.settings().tempo, 120);
    for (size_t n : {size_t(0), size_t(1), size_t(90), state.size() - 1}) assert(!loadState(restored, state.data(), n));
    // Real v1 field layout, with no parameter-count field and only the original IDs.
    std::vector<uint8_t> old(state.begin(), state.begin() + 8); old[4] = 1;
    old.insert(old.end(), state.begin() + 12, state.begin() + 12 + 9 * 8);
    old.insert(old.end(), state.begin() + 12 + ParamCount * 8, state.end());
    assert(loadState(restored, old.data(), old.size())); equal(restored.params[KeepSpeed].load(), 0); equal(plain(FadeIn, restored.params[FadeIn].load()), 5);
    equal(plain(FadeOut, restored.params[FadeOut].load()), 5); equal(plain(Root, restored.params[Root].load()), 48);
    auto before = saveState(restored); state[0] = 0;
    assert(!loadState(restored, state.data(), state.size())); assert(before == saveState(restored));
    auto peak = sample->peak(100, 900); equal(peak.lo, -899.f / 1024); equal(peak.hi, 899.f / 1024);
    SampleStore store; store.publish(ramp(64)); std::atomic<bool> running{true};
    std::thread audio([&] {
        Engine audioEngine; audioEngine.configure(config(Mode::Forward)); audioEngine.prepare(48000);
        while (running.load()) {
            auto p = store.pin(); audioEngine.setSample(p); audioEngine.noteOn(60, .1f);
            for (int i = 0; i < 16; ++i) { float a, b; audioEngine.render(a, b); assert(std::isfinite(a)); }
            store.unpin();
        }
    });
    for (int i = 0; i < 1500; ++i) store.publish(ramp(32 + i % 64));
    running.store(false); audio.join();
    std::cout << "PASS: loops, fades, latency, measured pitch, speed, note/bar sync, tempo automation, isolated UI stop, v1/v2 migration, bounds, concurrency\n";
}
