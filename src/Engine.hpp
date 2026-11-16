#pragma once
#include "PitchShifter.hpp"
#include "Effects.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace hasio {
constexpr int voiceCount = 16;
constexpr uint64_t maxSampleBytes = 192ull * 1024 * 1024;
enum class Mode { OneShot, Forward, Reverse, PingPong, ReverseOneShot };
// Keep old IDs stable for existing DAW automation. ID 8 remains a hidden legacy
// slot; never reuse it for a new control.
enum Param : uint32_t { ModeId, Start, End, Root, Tune, Gain, Attack, Release,
    LegacyCrossfade, FadeIn, FadeOut, KeepSpeed, PlaybackRate, SyncLength, Tempo,
    DistEnabled, DistType, DistAmount, DistTone, DistMix, ChorusEnabled, ChorusDepth, ChorusRate, ChorusWidth, ChorusDelay, ChorusFeedback, ChorusMix, ParamCount };
inline constexpr const char* modeNames[] = { "One-shot", "Forward", "Reverse", "Ping-pong", "Reverse shot" };
inline constexpr const char* paramNames[] = { "Playback mode", "Loop start", "Loop end", "Root note", "Tune", "Output", "Attack", "Release", "Legacy crossfade", "Fade In", "Fade Out", "Keep speed", "Playback speed", "Sync length", "Fallback tempo", "Distortion enabled", "Distortion type", "Distortion amount", "Distortion tone", "Distortion mix", "Chorus enabled", "Chorus depth", "Chorus rate", "Chorus width", "Chorus delay", "Chorus feedback", "Chorus mix" };
inline constexpr const char* distortionNames[] = { "Tube", "Saturate", "Clipping", "Asymmetrical", "Scream", "Aliasing" };
inline constexpr const char* lengthNames[] = { "Free", "4 bars", "2 bars", "1 bar", "1/2", "1/4", "1/8", "1/16", "1/32" };
inline constexpr int lengthCount = 9;
inline const double defaults[] = { .25, 0, 1, 60.0 / 127, .5, 48.0 / 66, .01, 115.0 / 2995, .1, .07071067811865475, .07071067811865475, 1, .5, 0, 100.0 / 380, 0, 0, .25, .5, 1, 0, .35, std::log(.35/.05)/std::log(100.0), 1, 11.0/29, 1.0/9, .35 };
inline double norm(double v) { return std::isfinite(v) ? std::clamp(v, 0.0, 1.0) : 0.0; }
inline double plain(uint32_t id, double v) {
    v = norm(v);
    switch (id) {
        case ModeId: return std::round(v * 4);
        case Root: return std::round(v * 127);
        case Tune: return v * 48 - 24;
        case Gain: return v * 66 - 60;
        case Attack: return v * 200;
        case Release: return 5 + v * 2995;
        case LegacyCrossfade: return v * 50;
        case FadeIn: case FadeOut: return v * v * 1000;
        case KeepSpeed: case DistEnabled: case ChorusEnabled: return v >= .5 ? 1 : 0;
        case PlaybackRate: return std::exp2(v * 4 - 2);
        case SyncLength: return std::round(v * (lengthCount - 1));
        case Tempo: return 20 + v * 380;
        case DistType: return std::round(v * 5);
        case ChorusRate: return .05 * std::pow(100, v);
        case ChorusDelay: return 1 + v * 29;
        case ChorusFeedback: return v * 90;
        case DistAmount: case DistTone: case DistMix: case ChorusDepth: case ChorusWidth: case ChorusMix: return v * 100;
        default: return v;
    }
}
inline double normalized(uint32_t id, double v) {
    switch (id) {
        case ModeId: return norm(v / 4);
        case Root: return norm(v / 127);
        case Tune: return norm((v + 24) / 48);
        case Gain: return norm((v + 60) / 66);
        case Attack: return norm(v / 200);
        case Release: return norm((v - 5) / 2995);
        case LegacyCrossfade: return norm(v / 50);
        case FadeIn: case FadeOut: return std::sqrt(norm(v / 1000));
        case KeepSpeed: case DistEnabled: case ChorusEnabled: return v >= .5 ? 1 : 0;
        case PlaybackRate: return norm((std::log2(std::max(.25, v)) + 2) / 4);
        case SyncLength: return norm(v / (lengthCount - 1));
        case Tempo: return norm((v - 20) / 380);
        case DistType: return norm(v / 5);
        case ChorusRate: return norm(std::log(std::max(.05, v) / .05) / std::log(100.0));
        case ChorusDelay: return norm((v - 1) / 29);
        case ChorusFeedback: return norm(v / 90);
        case DistAmount: case DistTone: case DistMix: case ChorusDepth: case ChorusWidth: case ChorusMix: return norm(v / 100);
        default: return norm(v);
    }
}
struct Peak { float lo = 0, hi = 0; };
struct Sample {
    double rate = 48000;
    std::string name;
    std::vector<float> left, right;
    std::vector<std::vector<Peak>> peaks;
    uint64_t serial = 0;
    size_t frames() const { return left.size(); }
    void buildPeaks();
    Peak peak(size_t first, size_t last) const;
};
struct Settings {
    Mode mode = Mode::Forward;
    double start = 0, end = 1, root = 60, tune = 0, gainDb = -12;
    double attackMs = 2, releaseMs = 120, fadeInMs = 5, fadeOutMs = 5;
    bool keepSpeed = true;
    double speed = 1, tempo = 120, beatsPerBar = 4;
    int syncLength = 0;
    FxSettings fx;
};
inline double playbackSpeed(const Settings& s, size_t frames, double sampleRate) {
    if (s.syncLength <= 0 || s.syncLength >= lengthCount || frames < 2) return std::clamp(s.speed, .25, 4.0);
    const double lo = std::clamp(std::floor(norm(s.start) * frames), 0.0, static_cast<double>(frames - 2));
    const double hi = std::clamp(std::ceil(norm(s.end) * frames), lo + 2, static_cast<double>(frames));
    const double period = s.mode == Mode::PingPong ? 2 * (hi - lo - 1) : hi - lo;
    const double beats = s.syncLength <= 3 ? s.beatsPerBar * std::exp2(3 - s.syncLength) : std::exp2(5 - s.syncLength);
    return period / sampleRate / (beats * 60 / s.tempo);
}
struct Note { int pitch = 60, id = -1, channel = 0; float velocity = 1; bool on = true, stopPreview = false; };
// One UI producer and one audio consumer. No allocation or locks on the audio thread.
template<size_t N> class NoteQueue {
    std::array<Note, N> data{};
    std::atomic<size_t> read{0}, write{0};
public:
    bool push(Note n) {
        auto w = write.load(std::memory_order_relaxed), next = (w + 1) % N;
        if (next == read.load(std::memory_order_acquire)) return false;
        data[w] = n; write.store(next, std::memory_order_release); return true;
    }
    bool pop(Note& n) {
        auto r = read.load(std::memory_order_relaxed);
        if (r == write.load(std::memory_order_acquire)) return false;
        n = data[r]; read.store((r + 1) % N, std::memory_order_release); return true;
    }
};

// Single-reader hazard pointer. The control thread retains ownership; the render
// callback publishes a pin before dereferencing and never destroys sample buffers.
class SampleStore {
    mutable std::mutex mutex;
    std::vector<std::shared_ptr<const Sample>> owned;
    std::shared_ptr<const Sample> current;
    std::atomic<const Sample*> desired{nullptr}, pinned{nullptr};
    uint64_t serial = 0;
public:
    void publish(std::shared_ptr<Sample> sample);
    std::shared_ptr<const Sample> snapshot() const;
    const Sample* pin();
    void unpin() { pinned.store(nullptr); }
};
struct Model {
    std::array<std::atomic<double>, ParamCount> params;
    SampleStore samples;
    NoteQueue<128> notes;
    std::atomic<bool> panic{false}, loading{false};
    std::atomic<double> playhead{-1};
    std::atomic<float> meter{0};
    std::atomic<int> activeVoices{0};
    std::atomic<double> hostTempo{120};
    std::atomic<bool> hostTempoValid{false};
    std::atomic<int> timeSigNumerator{4}, timeSigDenominator{4};
    mutable std::mutex statusMutex;
    std::string status;
    Model();
    Settings settings() const;
    void setStatus(std::string text);
    std::string getStatus() const;
    void preview(int pitch, bool on);
    void stopPreviewNotes();
    void setHostTiming(double bpm, int numerator, int denominator);
};

class Engine {
    struct Voice {
        bool active = false, releasing = false, draining = false, preview = false;
        int pitch = 60, id = -1, channel = 0, direction = 1;
        double position = 0, step = 1, pitchRatio = 1, sourceStep = 1, sourcePitch = 1;
        bool stretch = false;
        int tailRemaining = 0;
        float envelope = 0, releaseStep = 0, velocity = 0;
        uint64_t age = 0;
    };
    std::array<Voice, voiceCount> voices{};
    PitchShifter pitchShifter;
    Effects effects;
    std::array<std::array<float, PitchShifter::sourceWindowSize>, 2> sourceWindow{};
    const Sample* sample = nullptr;
    uint64_t sampleSerial = 0, age = 0;
    double outputRate = 48000, lo = 0, hi = 2, fadeIn = 0, fadeOut = 0;
    float gain = 0, targetGain = 0;
    Settings settings_;
    void updateRange();
    void tuneVoice(Voice& voice);
    void fillSourceWindow(const Voice& voice);
    float read(const std::vector<float>& channel, double position, bool wrap) const;
public:
    void prepare(double rate);
    // The caller must keep the sample alive until the next setSample call. In
    // realtime use, pin before setSample/configure/render and unpin afterwards.
    void setSample(const Sample* next);
    void configure(const Settings& settings);
    void noteOn(int pitch, float velocity, int id = -1, int channel = 0, bool preview = false);
    void noteOff(int pitch, int id = -1, int channel = 0, bool preview = false);
    void previewEvent(const Note& note);
    void allNotesOff();
    void stopChannel(int channel);
    void render(float& left, float& right);
    int activeCount() const;
    int transportCount() const;
    static constexpr int latencySamples() { return PitchShifter::latency; }
    double playhead() const;
};
std::shared_ptr<Sample> makeDemo();
} // namespace hasio
