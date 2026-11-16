#pragma once
#include <array>
#include <vector>

namespace hasio {
// Native distortion and chorus implementations.
// No proprietary DSP, binary payloads or assets are linked into this module.
struct FxSettings {
    bool distEnabled = false, chorusEnabled = false;
    int type = 0;
    double amount = .25, tone = .5, distMix = 1;
    double depth = .35, rate = .35, width = 1, delayMs = 12, feedback = .1, chorusMix = .35;
};
class Effects {
    struct Lowpass {
        double b0=0, b1=0, b2=0, a1=0, a2=0, z1=0, z2=0;
        void prepare(double cutoff, double rate, double q);
        double process(double x);
        void reset() { z1 = z2 = 0; }
    };
    struct Channel {
        std::array<Lowpass, 2> lowpass;
        double previous=0, toneLow=0, dcIn=0, dcOut=0, held=0, holdPhase=1;
        std::vector<float> delay;
    };
    std::array<Channel, 2> channels;
    FxSettings target{}, current{};
    std::array<double, 6> modes{1,0,0,0,0,0};
    double sampleRate=48000, smooth=1, toneCoefficient=1, dcCoefficient=0;
    double distortionWet=0, chorusWet=0, phase=0;
    size_t write=0;
    double delayed(int channel, double samples) const;
    double distort(int channel, double input);
public:
    void prepare(double sampleRate);
    void configure(const FxSettings& settings);
    void reset();
    void process(float& left, float& right);
};
}
