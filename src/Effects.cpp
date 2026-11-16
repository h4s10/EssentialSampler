#include "Effects.hpp"
#include <algorithm>
#include <cmath>

namespace hasio {
namespace {
constexpr double tau = 6.283185307179586;
double safe(double value, double lo, double hi, double fallback) { return std::isfinite(value) ? std::clamp(value, lo, hi) : fallback; }
double shape(int mode, double x, double drive) {
    switch (mode) {
        case 0: return (std::tanh(drive * x + .18) - std::tanh(.18)) / std::tanh(drive); // even + odd
        case 1: { const double z=drive*x; return std::tanh(z) - .12 * z * std::exp(-8*std::abs(z)); } // crossover notch
        case 2: return std::clamp(drive*x, -1.0, 1.0);
        case 3: return x >= 0 ? std::tanh(drive*x) : .55 * std::tanh(drive*x*1.8);
        case 4: return std::tanh(drive*2.5*x + .35*std::sin(drive*3*x) + .3) - std::tanh(.3);
        default: return x;
    }
}
}
void Effects::Lowpass::prepare(double cutoff, double rate, double q) {
    double w=tau*cutoff/rate, c=std::cos(w), a=std::sin(w)/(2*q), inv=1/(1+a);
    b0=(1-c)*.5*inv; b1=(1-c)*inv; b2=b0; a1=-2*c*inv; a2=(1-a)*inv; reset();
}
double Effects::Lowpass::process(double x) { double y=b0*x+z1; z1=b1*x-a1*y+z2; z2=b2*x-a2*y; return y; }
void Effects::prepare(double rate) {
    sampleRate=safe(rate, 8000, 384000, 48000);
    smooth=1-std::exp(-1/(.015*sampleRate));
    toneCoefficient=1-std::exp(-tau*800/sampleRate); dcCoefficient=std::exp(-tau*20/sampleRate);
    for (auto& c: channels) {
        c.delay.assign(static_cast<size_t>(std::ceil(sampleRate*.1))+8, 0);
        c.lowpass[0].prepare(sampleRate*.45, sampleRate*4, .5411961);
        c.lowpass[1].prepare(sampleRate*.45, sampleRate*4, 1.3065630);
    }
    reset();
}
void Effects::configure(const FxSettings& s) {
    target=s; target.type=std::clamp(s.type,0,5);
    target.amount=safe(s.amount,0,1,.25); target.tone=safe(s.tone,0,1,.5); target.distMix=safe(s.distMix,0,1,1);
    target.depth=safe(s.depth,0,1,.35); target.rate=safe(s.rate,.05,5,.35); target.width=safe(s.width,0,1,1);
    target.delayMs=safe(s.delayMs,1,30,12); target.feedback=safe(s.feedback,0,.9,.1); target.chorusMix=safe(s.chorusMix,0,1,.35);
}
void Effects::reset() {
    for (auto& c: channels) {
        std::fill(c.delay.begin(),c.delay.end(),0);
        for(auto& f:c.lowpass) f.reset();
        c.previous=c.toneLow=c.dcIn=c.dcOut=c.held=0; c.holdPhase=1;
    }
    current=target; distortionWet=target.distEnabled ? target.distMix : 0; chorusWet=target.chorusEnabled ? target.chorusMix : 0;
    modes.fill(0); modes[target.type]=1; write=0; phase=0;
}
double Effects::distort(int channel, double x) {
    auto& c=channels[channel];
    const double drive=std::exp(current.amount*std::log(32.0));
    // Non-digital modes use four interpolated sub-samples and a fourth-order
    // anti-alias filter. Aliasing intentionally uses sample-and-hold at base rate.
    double filtered=0;
    for(int step=1;step<=4;++step) {
        double in=c.previous+(x-c.previous)*step*.25, shaped=0;
        for(int mode=0;mode<5;++mode) if(modes[mode]>1.e-8) shaped+=modes[mode]*shape(mode,in,drive);
        filtered=c.lowpass[1].process(c.lowpass[0].process(shaped));
    }
    c.previous=x;
    if(c.holdPhase>=1) { c.holdPhase-=1; c.held=x; }
    c.holdPhase+=1/(1+current.amount*63);
    double effected=filtered+modes[5]*c.held;
    // Exact zero Amount is neutral at the middle Tone setting.
    double amountBlend=std::min(1.0,current.amount*8);
    double wet=x+(effected-x)*amountBlend;
    c.toneLow+=toneCoefficient*(wet-c.toneLow);
    double tilt=2*current.tone-1;
    wet=c.toneLow*std::exp2(-tilt)+(wet-c.toneLow)*std::exp2(tilt);
    double delta=wet-x, dc=delta-c.dcIn+dcCoefficient*c.dcOut;
    c.dcIn=delta; c.dcOut=std::abs(dc)<1.e-20 ? 0 : dc;
    return x+dc;
}
double Effects::delayed(int channel, double samples) const {
    const auto& buffer=channels[channel].delay;
    double at=static_cast<double>(write)-std::clamp(samples,1.0,static_cast<double>(buffer.size()-2));
    if(at<0) at+=buffer.size();
    size_t i=static_cast<size_t>(at), j=(i+1)%buffer.size();
    return buffer[i]+(buffer[j]-buffer[i])*(at-i);
}
void Effects::process(float& left, float& right) {
    auto slew=[&](double& v,double to) { v+=(to-v)*smooth; if(std::abs(v-to)<1.e-10) v=to; };
    slew(current.amount,target.amount); slew(current.tone,target.tone);
    slew(current.depth,target.depth); slew(current.rate,target.rate); slew(current.width,target.width);
    slew(current.delayMs,target.delayMs); slew(current.feedback,target.feedback);
    slew(distortionWet,target.distEnabled ? target.distMix : 0); slew(chorusWet,target.chorusEnabled ? target.chorusMix : 0);
    for(int mode=0;mode<6;++mode) slew(modes[mode], mode==target.type ? 1 : 0);
    double signal[2]={left,right};
    if(distortionWet>0) for(int ch=0;ch<2;++ch) signal[ch]+=(distort(ch,signal[ch])-signal[ch])*distortionWet;
    else for(auto& c:channels) { c.previous=0; c.toneLow=c.dcIn=c.dcOut=0; for(auto& f:c.lowpass)f.reset(); }
    if(!channels[0].delay.empty()) {
        double wet[2];
        const double base=current.delayMs*.001*sampleRate;
        const double depth=std::min(base*.85,current.depth*.008*sampleRate);
        for(int ch=0;ch<2;++ch) {
            double p=phase+ch*.25;
            // Two detuned copies per side, with different phases and excursions.
            wet[ch]=.5*(delayed(ch,base+depth*std::sin(tau*p)) + delayed(ch,base+depth*.7*std::sin(tau*(p+.43))));
            double input=chorusWet>0 ? signal[ch] : 0;
            channels[ch].delay[write]=static_cast<float>(input+wet[ch]*current.feedback);
        }
        double mid=(wet[0]+wet[1])*.5, side=(wet[0]-wet[1])*.5*current.width;
        signal[0]+=(mid+side-signal[0])*chorusWet; signal[1]+=(mid-side-signal[1])*chorusWet;
        write=(write+1)%channels[0].delay.size(); phase+=current.rate/sampleRate; if(phase>=1)phase-=1;
    }
    left=static_cast<float>(signal[0]); right=static_cast<float>(signal[1]);
}
}
