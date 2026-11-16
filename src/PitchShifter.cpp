#include "PitchShifter.hpp"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <stdexcept>

namespace hasio {
struct PitchShifter::Impl {
    static constexpr int n = windowSize, hop = n / 8, bins = n / 2 + 1;
    static constexpr double pi = 3.14159265358979323846, tau = pi * 2;
    struct Channel {
        std::array<float, n> input{}, overlap{}, delay{};
        std::array<float, hop> output{}, transitionOutput{};
        std::array<float, n> transitionOverlap{};
        std::array<double, bins> previousPhase{}, phase{};
        bool primed = false;
    };
    struct Voice {
        std::array<Channel, 2> channels;
        int rover = n - hop, delayHead = 0;
        float wet = 0;
        bool sourceMode = false;
        int sourceWarmup = 0, transitionSamples = 0;
        std::array<float, n> envelope{};
    };
    std::array<Voice, 16> voices{};
    std::array<float, n> window{}, real{}, imaginary{};
    std::array<float, bins> analysisMagnitude{}, analysisPhase{}, synthesisPhase{}, adjacentPhase{}, sine{}, cosine{};
    std::array<double, bins> magnitude{}, frequency{};
    FFTSetup fft = vDSP_create_fftsetup(11, kFFTRadix2);
    Impl() {
        if (!fft) throw std::runtime_error("Cannot initialize pitch FFT");
        for (int i = 0; i < n; ++i) window[i] = static_cast<float>(.5 - .5 * std::cos(tau * i / n));
    }
    ~Impl() { vDSP_destroy_fftsetup(fft); }
    void transform(Channel& channel, double ratio, const float* source = nullptr) {
        for (int i = 0; i < n; ++i) { real[i] = (source ? source[i] : channel.input[i]) * window[i]; imaginary[i] = 0; }
        DSPSplitComplex spectrum{real.data(), imaginary.data()};
        vDSP_fft_zip(fft, &spectrum, 1, 11, FFT_FORWARD);
        const int binCount = bins;
        vDSP_zvabs(&spectrum, 1, analysisMagnitude.data(), 1, bins);
        vvatan2f(analysisPhase.data(), imaginary.data(), real.data(), &binCount);
        if (source) {
            // A fixed nearby analysis hop avoids ambiguous frequency estimates
            // even when consecutive transport positions are many windows apart.
            for (int i = 0; i < n; ++i) { real[i] = source[i + hop] * window[i]; imaginary[i] = 0; }
            vDSP_fft_zip(fft, &spectrum, 1, 11, FFT_FORWARD);
            vvatan2f(adjacentPhase.data(), imaginary.data(), real.data(), &binCount);
        }
        magnitude.fill(0); frequency.fill(0);
        for (int k = 0; k < bins; ++k) {
            double amplitude = analysisMagnitude[k];
            double phase = analysisPhase[k];
            double deviation = (source ? adjacentPhase[k] - phase : phase - channel.previousPhase[k]) - tau * k * hop / n;
            deviation = std::remainder(deviation, tau);
            double bin = (source || channel.primed) ? k + deviation * n / (tau * hop) : k;
            channel.previousPhase[k] = phase;
            double destination = k * ratio;
            if (destination >= bins) continue;
            int target = static_cast<int>(destination);
            magnitude[target] += amplitude;
            frequency[target] += amplitude * bin * ratio;
            if (!channel.primed) channel.phase[target] = phase;
        }
        channel.primed = true;
        real.fill(0); imaginary.fill(0);
        for (int k = 0; k < bins; ++k) {
            double bin = magnitude[k] > 1.e-12 ? frequency[k] / magnitude[k] : k;
            channel.phase[k] = std::remainder(channel.phase[k] + tau * hop * bin / n, tau);
            synthesisPhase[k] = static_cast<float>(channel.phase[k]);
        }
        vvsincosf(sine.data(), cosine.data(), synthesisPhase.data(), &binCount);
        for (int k = 0; k < bins; ++k) {
            real[k] = static_cast<float>(magnitude[k]) * cosine[k];
            imaginary[k] = static_cast<float>(magnitude[k]) * sine[k];
            if (k > 0 && k < n / 2) { real[n - k] = real[k]; imaginary[n - k] = -imaginary[k]; }
        }
        imaginary[0] = imaginary[n / 2] = 0;
        vDSP_fft_zip(fft, &spectrum, 1, 11, FFT_INVERSE);
        // Periodic Hann windows at 8x overlap sum their squares to exactly 3.
        for (int i = 0; i < n; ++i) channel.overlap[i] += real[i] * window[i] / (n * 3.f);
        std::copy_n(channel.overlap.begin(), hop, channel.output.begin());
        std::move(channel.overlap.begin() + hop, channel.overlap.end(), channel.overlap.begin());
        std::fill(channel.overlap.end() - hop, channel.overlap.end(), 0.f);
    }
};
PitchShifter::PitchShifter() : impl(std::make_unique<Impl>()) {}
PitchShifter::~PitchShifter() = default;
void PitchShifter::reset(size_t index) {
    auto& voice = impl->voices[index];
    for (auto& c : voice.channels) {
        c.input.fill(0); c.overlap.fill(0); c.delay.fill(0); c.output.fill(0);
        c.transitionOutput.fill(0); c.transitionOverlap.fill(0);
        c.previousPhase.fill(0); c.phase.fill(0); c.primed = false;
    }
    voice.rover = Impl::n - Impl::hop; voice.delayHead = 0; voice.wet = 0; voice.envelope.fill(0); voice.sourceMode = false; voice.sourceWarmup = 0; voice.transitionSamples = 0;
}
bool PitchShifter::needsSourceWindow(size_t index) const { return impl->voices[index].rover == Impl::n - 1; }
void PitchShifter::process(size_t index, float& left, float& right, double ratio,
                           bool sourceMode, const float* sourceLeft, const float* sourceRight, float envelope) {
    auto& v = impl->voices[index];
    if (sourceMode && !v.sourceMode) {
        // Carry already processed streaming overlap separately: it contains its
        // envelope, whereas new source overlap needs the delayed envelope below.
        // Preserve synthesis phase so a tuned note never falls back to raw pitch.
        for (auto& c : v.channels) {
            c.transitionOutput = c.output; c.transitionOverlap = c.overlap;
            c.overlap.fill(0); c.output.fill(0);
        }
        v.sourceMode = true; v.transitionSamples = Impl::n;
        v.sourceWarmup = v.wet > 0 ? 0 : Impl::n - 2 * Impl::hop;
    }
    if (v.sourceWarmup > 0) --v.sourceWarmup;
    float desired = (sourceMode || std::abs(ratio - 1) >= 1.e-7) && v.sourceWarmup == 0 ? 1.f : 0.f;
    float delayedEnvelope = v.envelope[v.delayHead]; v.envelope[v.delayHead] = envelope;
    v.wet += std::clamp(desired - v.wet, -1.f / Impl::hop, 1.f / Impl::hop);
    float* samples[] = {&left, &right};
    for (int ch = 0; ch < 2; ++ch) {
        auto& c = v.channels[ch]; float input = *samples[ch];
        c.input[v.rover] = input;
        float dry = c.delay[v.delayHead]; c.delay[v.delayHead] = input;
        float wet = c.output[v.rover - (Impl::n - Impl::hop)];
        if (sourceMode) {
            wet *= delayedEnvelope;
            if (v.transitionSamples > 0) wet += c.transitionOutput[v.rover - (Impl::n - Impl::hop)];
        }
        *samples[ch] = dry + v.wet * (wet - dry);
    }
    if (v.transitionSamples > 0) --v.transitionSamples;
    v.delayHead = (v.delayHead + 1) % Impl::n;
    if (++v.rover < Impl::n) return;
    v.rover = Impl::n - Impl::hop;
    const float* sources[] = {sourceLeft, sourceRight};
    for (int ch = 0; ch < 2; ++ch) {
        auto& c = v.channels[ch];
        if (v.transitionSamples > 0) {
            std::copy_n(c.transitionOverlap.begin(), Impl::hop, c.transitionOutput.begin());
            std::move(c.transitionOverlap.begin() + Impl::hop, c.transitionOverlap.end(), c.transitionOverlap.begin());
            std::fill(c.transitionOverlap.end() - Impl::hop, c.transitionOverlap.end(), 0.f);
        }
        if (sourceMode || desired > 0 || v.wet > 0) impl->transform(c, ratio, sourceMode ? sources[ch] : nullptr);
        else { c.primed = false; c.output.fill(0); c.overlap.fill(0); }
        std::move(c.input.begin() + Impl::hop, c.input.end(), c.input.begin());
    }
}
}
