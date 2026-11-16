#pragma once
#include <cstddef>
#include <memory>

namespace hasio {
// Preallocated stereo phase-vocoder bank. Each voice has an independent phase
// history. All voices share one FFT setup and scratch space on the audio thread.
class PitchShifter {
    struct Impl;
    std::unique_ptr<Impl> impl;
public:
    static constexpr int windowSize = 2048;
    static constexpr int latency = windowSize;
    static constexpr int tail = windowSize * 2;
    PitchShifter();
    ~PitchShifter();
    PitchShifter(const PitchShifter&) = delete;
    PitchShifter& operator=(const PitchShifter&) = delete;
    void reset(size_t voice);
    static constexpr int hopSize = windowSize / 8;
    static constexpr int sourceWindowSize = windowSize + hopSize;
    bool needsSourceWindow(size_t voice) const;
    // Source mode analyses two nearby windows at the natural sample-reading rate.
    // Transport speed changes their source position, never their bandwidth.
    // Provide sourceWindowSize samples per channel only when needsSourceWindow().
    void process(size_t voice, float& left, float& right, double ratio,
                 bool sourceMode = false, const float* sourceLeft = nullptr,
                 const float* sourceRight = nullptr, float envelope = 1);
};
}
