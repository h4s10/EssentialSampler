#include "Effects.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <vector>
using namespace hasio;
constexpr double tau = 6.283185307179586;
int main() {
    Effects fx; FxSettings s; fx.prepare(48000); fx.configure(s);
    // Disabled FX must be bit-transparent, including signals above unity.
    for (int i = 0; i < 10000; ++i) {
        float a = float(2 * std::sin(i * .033)), b = -a, l = a, r = b;
        fx.process(l, r); assert(l == a && r == b);
    }
    // 100% dry remains exact with both modules enabled.
    s.distEnabled = s.chorusEnabled = true; s.distMix = s.chorusMix = 0;
    fx.configure(s);
    for (int i = 0; i < 5000; ++i) { float l = .3f, r = -.2f; fx.process(l, r); assert(l == .3f && r == -.2f); }
    // Six algorithms really change the signal and do not collapse to one curve.
    std::vector<std::vector<float>> modes;
    s.chorusEnabled = false; s.distMix = 1; s.amount = .8; s.tone = .5;
    for (int mode = 0; mode < 6; ++mode) {
        fx.reset(); s.type = mode; fx.configure(s); std::vector<float> out;
        double difference = 0, dc = 0;
        for (int i = 0; i < 24000; ++i) {
            float dry = float(.5 * std::sin(tau * 220 * i / 48000)), l = dry, r = dry;
            fx.process(l, r); assert(std::isfinite(l) && std::abs(l) < 4 && l == r);
            if (i >= 12000) { out.push_back(l); difference += std::abs(l - dry); dc += l; }
        }
        assert(difference > 100 && std::abs(dc / out.size()) < .02);
        for (const auto& previous : modes) { double delta = 0; for (size_t i = 0; i < out.size(); ++i) delta += std::abs(previous[i] - out[i]); assert(delta > 10); }
        modes.push_back(out);
    }
    // Amount=0 and neutral Tone is clean; Tone dark/bright changes spectral balance.
    s = {}; s.distEnabled=true; s.distMix=1; s.amount=0; s.tone=.5;
    fx.configure(s); fx.reset();
    for(int i=0;i<10000;++i) { float dry=float(.7*std::sin(i*.035)),l=dry,r=dry; fx.process(l,r); assert(std::abs(l-dry)<1.e-6); }
    auto toneEnergy=[&](double tone,double hz) {
        s.amount=.5; s.tone=tone; fx.configure(s); fx.reset(); double energy=0;
        for(int i=0;i<24000;++i) { float l=float(.2*std::sin(tau*hz*i/48000)),r=l; fx.process(l,r); if(i>12000)energy+=l*l; }
        return energy;
    };
    assert(toneEnergy(0,80)>toneEnergy(1,80)*2);
    assert(toneEnergy(1,8000)>toneEnergy(0,8000)*2);
    // Full-wet chorus impulse delay, zero depth and feedback: no early wet output.
    fx.prepare(48000); s = {}; s.chorusEnabled = true; s.chorusMix = 1; s.depth = 0; s.delayMs = 20; s.feedback = 0;
    fx.configure(s);
    for (int i = 0; i < 24000; ++i) { float l = 0, r = 0; fx.process(l,r); }
    double wet = 0;
    for (int i = 0; i < 1200; ++i) {
        float l = i == 0 ? 1.f : 0.f, r = l; fx.process(l,r);
        if (i > 1 && i < 959) assert(std::abs(l) < 1.e-6);
        if (i >= 959 && i <= 961) wet += std::abs(l);
    }
    assert(wet > .99);
    // Width=0 makes the wet signal mono; width=1 with modulation produces stereo.
    for (double width : {0.0, 1.0}) {
        fx.prepare(48000); s.depth = 1; s.width = width; s.rate = 1.3; fx.configure(s);
        double stereo = 0;
        for (int i = 0; i < 48000; ++i) { float l = float(.5 * std::sin(tau * 440 * i / 48000)), r = l; fx.process(l,r); if(i>24000) stereo += std::abs(l-r); }
        if (width == 0) assert(stereo < .01); else assert(stereo > 100);
    }
    // Rate changes audible modulation; feedback yields a decaying echo train.
    auto chorusOutput=[&](double rate) {
        fx.prepare(48000); s={}; s.chorusEnabled=true; s.chorusMix=1; s.depth=1; s.rate=rate;
        fx.configure(s); fx.reset(); std::vector<float> out;
        for(int i=0;i<48000;++i) { float l=float(.5*std::sin(tau*440*i/48000)),r=l; fx.process(l,r); out.push_back(l); }
        return out;
    };
    auto slow=chorusOutput(.05),fast=chorusOutput(5); double rateDelta=0;
    for(size_t i=0;i<slow.size();++i) rateDelta+=std::abs(slow[i]-fast[i]); assert(rateDelta>100);
    fx.prepare(48000); s={}; s.chorusEnabled=true; s.chorusMix=1; s.depth=0; s.delayMs=10; s.feedback=.5;
    fx.configure(s); fx.reset(); std::vector<float> impulse;
    for(int i=0;i<2000;++i) { float l=i==0 ? 1.f : 0.f,r=l; fx.process(l,r); impulse.push_back(l); }
    assert(std::abs(impulse[480]-1)<1.e-6 && std::abs(impulse[960]-.5)<1.e-6 && std::abs(impulse[1440]-.25)<1.e-6);
    // Automation, highest feedback and all supported rates remain bounded. Reset clears tails.
    for (double rate : {8000., 44100., 48000., 96000., 192000., 384000.}) {
        fx.prepare(rate); s = {}; s.chorusEnabled = s.distEnabled = true; s.chorusMix = s.distMix = 1; s.feedback = .9;
        s.delayMs = 1; s.depth = 1; s.amount = 1;
        for (int i = 0; i < 24000; ++i) {
            if (i % 1000 == 0) { s.type = (i / 1000) % 6; s.rate = (i % 2000) ? .05 : 5; s.tone = (i % 2000) ? 0 : 1; fx.configure(s); }
            float l = i < 12000 ? float(2 * std::sin(i * .21)) : 0, r = -l; fx.process(l,r);
            assert(std::isfinite(l) && std::isfinite(r) && std::abs(l) < 32 && std::abs(r) < 32);
        }
        fx.reset(); for (int i = 0; i < 100; ++i) { float l=0,r=0; fx.process(l,r); assert(l==0 && r==0); }
    }
    std::cout << "PASS: FX dry identity, six distinct distortion modes, DC control, chorus delay/stereo, extreme settings/rates, reset\n";
}
