#include "Engine.hpp"
#include <cassert>
#include <iostream>
using namespace hasio;
constexpr double tau=6.283185307179586;
int main() {
    Engine engine; Settings cfg; cfg.syncLength=8; cfg.tempo=120; cfg.keepSpeed=true; cfg.gainDb=0; cfg.attackMs=0; cfg.fadeInMs=cfg.fadeOutMs=0;
    auto sample=std::make_shared<Sample>(); sample->rate=48000; sample->left.resize(144000); sample->right.resize(144000);
    // With FX/fades off, a 3-second sample fits into 1/32 (62.5 ms, 48x)
    // without throwing away its 1–18 kHz spectrum before pitch compensation.
    for(auto mode:{Mode::Forward,Mode::Reverse}) for(double hz:{220.,1000.,6000.,10000.,18000.}) {
        for(size_t i=0;i<sample->frames();++i) sample->left[i]=sample->right[i]=float(.5*std::sin(tau*hz*i/sample->rate));
        cfg.mode=mode; engine.configure(cfg); engine.prepare(48000); engine.setSample(sample.get()); engine.noteOn(60,1);
        double re=0,im=0,energy=0; constexpr int count=48000;
        for(int i=0;i<72000;++i) {
            float l,r; engine.render(l,r); assert(std::isfinite(l) && l==r && std::abs(l)<2);
            if(i>=24000) { re+=l*std::cos(tau*hz*i/48000); im+=l*std::sin(tau*hz*i/48000); energy+=l*l; }
        }
        double amplitude=2*std::hypot(re,im)/count;
        std::cout<<(mode==Mode::Forward?"Forward":"Reverse")<<" 1/32 "<<hz<<" Hz: amplitude "<<amplitude<<std::endl;
        assert(amplitude>.3 && amplitude<.75);
        assert(energy/count<.5);
    }
    // Free rate changes and return to unity preserve velocity, bandwidth, latency
    // and eventually silence a released voice. Include a simultaneous Tune edit.
    cfg={}; cfg.mode=Mode::Reverse; cfg.keepSpeed=true; cfg.gainDb=0; cfg.attackMs=0; cfg.releaseMs=5; cfg.fadeInMs=cfg.fadeOutMs=0;
    for(size_t i=0;i<sample->frames();++i) sample->left[i]=sample->right[i]=float(.5*std::sin(tau*6000*i/48000));
    engine.configure(cfg); engine.prepare(48000); engine.setSample(sample.get()); engine.noteOn(60,.1f);
    for(int stage=0;stage<5;++stage) {
        const double speeds[]={1,4,1,.25,1}; cfg.speed=speeds[stage]; cfg.tune=stage==4 ? -12 : 0; engine.configure(cfg);
        double re=0,im=0; double hz=stage==4 ? 3000 : 6000;
        for(int i=0;i<24000;++i) {
            float l,r; engine.render(l,r); assert(std::isfinite(l) && std::abs(l)<.12 && l==r);
            if(stage==0 && i<Engine::latencySamples()) assert(l==0);
            if(i>=12000) {re+=l*std::cos(tau*hz*i/48000); im+=l*std::sin(tau*hz*i/48000);}
        }
        assert(2*std::hypot(re,im)/12000>.025);
    }
    engine.noteOff(60);
    for(int i=0;i<8192;++i) {float l,r;engine.render(l,r);if(i>6000)assert(l==0 && r==0);}
    assert(engine.activeCount()==0);
    // Transposition still works after compression; test both sides of unity.
    for(double semitones:{-12.,12.}) {
        cfg.syncLength=8; cfg.tune=semitones; cfg.mode=Mode::Reverse;
        engine.configure(cfg); engine.prepare(48000); engine.setSample(sample.get()); engine.noteOn(60,1);
        double re=0,im=0,hz=6000*std::exp2(semitones/12);
        for(int i=0;i<72000;++i) {float l,r;engine.render(l,r);if(i>=24000){re+=l*std::cos(tau*hz*i/48000);im+=l*std::sin(tau*hz*i/48000);}}
        assert(2*std::hypot(re,im)/48000>.25);
    }
    // Both one-shot directions stay silent until the reported latency and finish
    // after exactly 1/32 of source transport plus bounded processor drain.
    for(auto mode:{Mode::OneShot,Mode::ReverseOneShot}) {
        cfg.mode=mode;cfg.tune=0; engine.configure(cfg);engine.prepare(48000);engine.setSample(sample.get());engine.noteOn(60,1);
        int transport=0,frames=0; double energy=0;
        while(engine.activeCount()) { if(engine.transportCount())++transport;float l,r;engine.render(l,r);if(frames<Engine::latencySamples())assert(l==0);energy+=l*l;++frames;assert(frames<12000); }
        assert(transport==3000 && energy>30);
    }
    // Reapplying the same settings each host block must not rewind a draining
    // one-shot's analysis position. Compare its actual final audio, not counters.
    for(auto mode:{Mode::OneShot,Mode::ReverseOneShot}) {
        cfg.mode=mode; cfg.syncLength=8; cfg.tune=0;
        for(size_t i=0;i<sample->frames();++i) {
            double hz=i<sample->frames()/2 ? 1000 : 10000;
            sample->left[i]=sample->right[i]=float(.5*std::sin(tau*hz*i/48000));
        }
        auto render=[&](int blockSize) {
            Engine e;e.configure(cfg);e.prepare(48000);e.setSample(sample.get());e.noteOn(60,1);std::vector<float> output;
            for(int i=0;i<8192;++i) {if(blockSize && i%blockSize==0)e.configure(cfg);float l,r;e.render(l,r);output.push_back(l);}
            return output;
        };
        auto continuous=render(0),blocked=render(256);
        assert(continuous==blocked);
    }
    // A voice already transposed by Tune must never fall back to unshifted dry
    // audio while its first speed edit warms source analysis.
    cfg={};cfg.mode=Mode::Forward;cfg.keepSpeed=true;cfg.gainDb=0;cfg.attackMs=0;cfg.fadeInMs=cfg.fadeOutMs=0;cfg.tune=12;
    for(size_t i=0;i<sample->frames();++i)sample->left[i]=sample->right[i]=float(.5*std::sin(tau*1000*i/48000));
    engine.configure(cfg);engine.prepare(48000);engine.setSample(sample.get());engine.noteOn(60,1);
    for(int i=0;i<24000;++i){float l,r;engine.render(l,r);}
    cfg.speed=2;engine.configure(cfg);double wrongRe=0,wrongIm=0,rightRe=0,rightIm=0;
    for(int i=0;i<1440;++i){float l,r;engine.render(l,r);wrongRe+=l*std::cos(tau*1000*i/48000);wrongIm+=l*std::sin(tau*1000*i/48000);rightRe+=l*std::cos(tau*2000*i/48000);rightIm+=l*std::sin(tau*2000*i/48000);}
    assert(std::hypot(rightRe,rightIm)>3*std::hypot(wrongRe,wrongIm));
    // Localized high-frequency attacks must not fall between distant source
    // windows when 3 seconds are compressed into 62.5ms.
    cfg.tune=0;cfg.syncLength=8;
    for(auto mode:{Mode::OneShot,Mode::ReverseOneShot})for(int offset:{0,5000,12000,17000,50000,140000}){
        cfg.mode=mode;std::fill(sample->left.begin(),sample->left.end(),0);
        for(int i=0;i<1500;++i)sample->left[offset+i]=float(.5*std::sin(tau*6000*i/48000)*(.5-.5*std::cos(tau*i/1499)));
        sample->right=sample->left;sample->buildPeaks();
        engine.configure(cfg);engine.prepare(48000);engine.setSample(sample.get());engine.noteOn(60,1);double energy=0;
        for(int i=0;i<8192;++i){float l,r;engine.render(l,r);energy+=l*l;}
        assert(energy>.01);
    }
    std::cout<<"PASS: original-frequency energy retained through extreme 1/32 compression in both directions\n";
}
