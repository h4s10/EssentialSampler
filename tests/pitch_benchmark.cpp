#include "Engine.hpp"
#include <chrono>
#include <iostream>
int main() {
    for (bool compressed : {false, true}) {
        hasio::Engine engine; auto sample = hasio::makeDemo();
        hasio::Settings settings; settings.tune = 7; settings.keepSpeed = true;
        settings.fx.distEnabled = settings.fx.chorusEnabled = true; settings.fx.amount = .65;
        if (compressed) { settings.mode = hasio::Mode::Reverse; settings.syncLength = 8; }
        engine.configure(settings); engine.prepare(48000); engine.setSample(sample.get());
        for (int i = 0; i < 16; ++i) engine.noteOn(52 + i, .05f);
        float l = 0, r = 0;
        for (int i = 0; i < 4096; ++i) engine.render(l, r);
        auto begin = std::chrono::steady_clock::now();
        for (int i = 0; i < 480000; ++i) engine.render(l, r);
        double elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        std::cout << "16 stereo voices + Distortion/Chorus, " << (compressed ? "Reverse 1/32 (48x)" : "Free 1x")
                  << ", 10s at 48kHz: " << elapsed << "s (" << elapsed * 10 << "% of realtime)\n";
        if (!std::isfinite(l) || !std::isfinite(r)) return 1;
    }
}
