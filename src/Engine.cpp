#include "Engine.hpp"
#include <limits>

namespace hasio {
void Sample::buildPeaks() {
    peaks.clear();
    if (left.empty()) return;
    std::vector<Peak> level((frames() + 63) / 64);
    for (size_t b = 0; b < level.size(); ++b) {
        Peak p{1, -1};
        for (size_t i = b * 64; i < std::min(frames(), (b + 1) * 64); ++i) {
            p.lo = std::min({p.lo, left[i], right[i]});
            p.hi = std::max({p.hi, left[i], right[i]});
        }
        level[b] = p;
    }
    peaks.push_back(std::move(level));
    while (peaks.back().size() > 1) {
        const auto& prev = peaks.back();
        std::vector<Peak> next((prev.size() + 1) / 2);
        for (size_t i = 0; i < next.size(); ++i) {
            next[i] = prev[i * 2];
            if (i * 2 + 1 < prev.size()) {
                next[i].lo = std::min(next[i].lo, prev[i * 2 + 1].lo);
                next[i].hi = std::max(next[i].hi, prev[i * 2 + 1].hi);
            }
        }
        peaks.push_back(std::move(next));
    }
}
Peak Sample::peak(size_t first, size_t last) const {
    if (frames() == 0) return {};
    first = std::min(first, frames() - 1);
    last = std::clamp(last, first + 1, frames());
    Peak p{1, -1};
    while (first < last) {
        size_t level = 0, block = 64;
        while (level + 1 < peaks.size() && first % (block * 2) == 0 && block * 2 <= last - first) { ++level; block *= 2; }
        if (!peaks.empty() && first % block == 0 && first + block <= last) {
            auto v = peaks[level][first / block];
            p.lo = std::min(p.lo, v.lo); p.hi = std::max(p.hi, v.hi); first += block;
        } else {
            p.lo = std::min({p.lo, left[first], right[first]});
            p.hi = std::max({p.hi, left[first], right[first]}); ++first;
        }
    }
    return p;
}
void SampleStore::publish(std::shared_ptr<Sample> s) {
    std::lock_guard<std::mutex> lock(mutex);
    if (s) s->serial = ++serial;
    current = std::move(s);
    if (current) owned.push_back(current);
    desired.store(current.get());
    auto hazard = pinned.load();
    owned.erase(std::remove_if(owned.begin(), owned.end(), [&](auto& p) {
        return p.get() != current.get() && p.get() != hazard;
    }), owned.end());
}
std::shared_ptr<const Sample> SampleStore::snapshot() const {
    std::lock_guard<std::mutex> lock(mutex); return current;
}
const Sample* SampleStore::pin() {
    const Sample* p;
    do { p = desired.load(); pinned.store(p); } while (p != desired.load());
    return p;
}
Model::Model() {
    for (uint32_t i = 0; i < ParamCount; ++i) params[i].store(defaults[i]);
    samples.publish(makeDemo());
}
Settings Model::settings() const {
    Settings result{static_cast<Mode>(static_cast<int>(plain(ModeId, params[ModeId].load()))),
        norm(params[Start].load()), norm(params[End].load()), plain(Root, params[Root].load()),
        plain(Tune, params[Tune].load()), plain(Gain, params[Gain].load()),
        plain(Attack, params[Attack].load()), plain(Release, params[Release].load()),
        plain(FadeIn, params[FadeIn].load()), plain(FadeOut, params[FadeOut].load()),
        plain(KeepSpeed, params[KeepSpeed].load()) > .5,
        plain(PlaybackRate, params[PlaybackRate].load()),
        hostTempoValid.load() ? hostTempo.load() : plain(Tempo, params[Tempo].load()),
        timeSigNumerator.load() * 4.0 / timeSigDenominator.load(),
        static_cast<int>(plain(SyncLength, params[SyncLength].load())), {}};
    auto& fx = result.fx;
    fx.distEnabled = plain(DistEnabled, params[DistEnabled]) > .5;
    fx.type = static_cast<int>(plain(DistType, params[DistType]));
    fx.amount = norm(params[DistAmount]); fx.tone = norm(params[DistTone]); fx.distMix = norm(params[DistMix]);
    fx.chorusEnabled = plain(ChorusEnabled, params[ChorusEnabled]) > .5;
    fx.depth = norm(params[ChorusDepth]); fx.rate = plain(ChorusRate, params[ChorusRate]);
    fx.width = norm(params[ChorusWidth]); fx.delayMs = plain(ChorusDelay, params[ChorusDelay]);
    fx.feedback = plain(ChorusFeedback, params[ChorusFeedback]) / 100; fx.chorusMix = norm(params[ChorusMix]);
    return result;
}
void Model::setStatus(std::string s) { std::lock_guard<std::mutex> lock(statusMutex); status = std::move(s); }
std::string Model::getStatus() const { std::lock_guard<std::mutex> lock(statusMutex); return status; }
void Model::preview(int pitch, bool on) {
    if (!notes.push({pitch, -1, 15, .8f, on})) panic.store(true);
}
void Model::stopPreviewNotes() {
    if (!notes.push({0, -1, 15, 0, false, true})) panic.store(true);
}
void Model::setHostTiming(double bpm, int numerator, int denominator) {
    bool valid = std::isfinite(bpm) && bpm >= 1 && bpm <= 1000;
    if (valid) hostTempo.store(bpm);
    hostTempoValid.store(valid);
    bool validMeter = numerator > 0 && numerator <= 64 && denominator > 0 && denominator <= 64 && (denominator & (denominator - 1)) == 0;
    timeSigNumerator.store(validMeter ? numerator : 4);
    timeSigDenominator.store(validMeter ? denominator : 4);
}
void Engine::prepare(double rate) {
    outputRate = std::isfinite(rate) && rate >= 8000 ? rate : 48000;
    effects.prepare(outputRate); allNotesOff(); sample = nullptr; sampleSerial = 0; gain = targetGain; updateRange();
}
void Engine::setSample(const Sample* s) {
    if (s != sample || (s && s->serial != sampleSerial)) {
        allNotesOff(); sampleSerial = s ? s->serial : 0;
    }
    sample = s; updateRange();
}
void Engine::configure(const Settings& s) {
    if (settings_.mode != s.mode) allNotesOff();
    settings_ = s; effects.configure(s.fx);
    targetGain = static_cast<float>(std::pow(10, s.gainDb / 20));
    updateRange();
    for (auto& v : voices) if (v.active) {
        tuneVoice(v);
        if (!v.draining && (v.position < lo || v.position >= hi)) v.position = v.direction > 0 ? lo : hi - 1;
    }
}
void Engine::updateRange() {
    if (!sample || sample->frames() < 2) { lo = 0; hi = 2; fadeIn = fadeOut = 0; return; }
    double n = static_cast<double>(sample->frames());
    lo = std::clamp(std::floor(norm(settings_.start) * n), 0.0, n - 2);
    hi = std::clamp(std::ceil(norm(settings_.end) * n), lo + 2, n);
    fadeIn = std::min(std::max(0.0, settings_.fadeInMs * .001 * sample->rate), (hi - lo - 1) * .5);
    fadeOut = std::min(std::max(0.0, settings_.fadeOutMs * .001 * sample->rate), (hi - lo - 1) * .5);
}
void Engine::tuneVoice(Voice& v) {
    double noteOffset = v.pitch - settings_.root;
    // Tune never changes the transport. Keep speed also moves MIDI transposition
    // into the pitch processor; otherwise MIDI retains classic sampler varispeed.
    bool fixedDuration = settings_.keepSpeed || settings_.syncLength > 0;
    double speed = playbackSpeed(settings_, sample->frames(), sample->rate);
    v.step = sample->rate / outputRate * speed * (fixedDuration ? 1 : std::pow(2, noteOffset / 12));
    v.sourcePitch = std::pow(2, (settings_.tune + (fixedDuration ? noteOffset : 0)) / 12);
    v.sourceStep = v.step / speed;
    // Keep the source-analysis path for this voice after its first speed edit;
    // switching back to streaming analysis would mix differently scaled OLA tails.
    v.stretch = v.stretch || std::abs(speed - 1) >= 1.e-7;
    v.pitchRatio = v.sourcePitch / speed;
}
void Engine::noteOn(int pitch, float velocity, int id, int channel, bool preview) {
    if (velocity <= 0) { noteOff(pitch, id, channel, preview); return; }
    if (!sample || sample->frames() < 2 || pitch < 0 || pitch > 127) return;
    auto it = std::find_if(voices.begin(), voices.end(), [](auto& v) { return !v.active; });
    if (it == voices.end()) it = std::min_element(voices.begin(), voices.end(), [](auto& a, auto& b) { return a.age < b.age; });
    auto& v = *it; v = {};
    v.active = true; v.pitch = pitch; v.id = id; v.channel = channel; v.age = ++age; v.preview = preview;
    v.velocity = std::clamp(velocity, 0.f, 1.f);
    v.direction = settings_.mode == Mode::Reverse || settings_.mode == Mode::ReverseOneShot ? -1 : 1;
    v.position = v.direction > 0 ? lo : hi - 1;
    tuneVoice(v); pitchShifter.reset(static_cast<size_t>(&v - voices.data()));
    v.envelope = settings_.attackMs <= 0 ? 1.f : 0.f;
}
void Engine::noteOff(int pitch, int id, int channel, bool preview) {
    if (settings_.mode == Mode::OneShot || settings_.mode == Mode::ReverseOneShot) return;
    for (auto& v : voices) if (v.active && v.preview == preview && v.channel == channel && (id >= 0 ? v.id == id : v.pitch == pitch)) {
        v.releasing = true;
        v.releaseStep = v.envelope / static_cast<float>(std::max(1.0, settings_.releaseMs * .001 * outputRate));
    }
}
void Engine::previewEvent(const Note& n) {
    if (n.stopPreview) { for (auto& v : voices) if (v.preview) v.active = false; }
    else if (n.on) noteOn(n.pitch, n.velocity, n.id, n.channel, true);
    else noteOff(n.pitch, n.id, n.channel, true);
}
void Engine::stopChannel(int channel) {
    for (auto& v : voices) if (v.active && !v.preview && v.channel == channel) {
        v.releasing = true; v.releaseStep = std::max(v.envelope, .0001f) / std::max(1.0, outputRate * .002);
    }
}
void Engine::allNotesOff() { for (auto& v : voices) v.active = false; effects.reset(); }
float Engine::read(const std::vector<float>& data, double p, bool wrap) const {
    p = std::clamp(p, lo, hi - 1.e-7);
    auto i = static_cast<size_t>(p), j = i + 1;
    if (j >= static_cast<size_t>(hi)) j = wrap ? static_cast<size_t>(lo) : static_cast<size_t>(hi - 1);
    float f = static_cast<float>(p - static_cast<double>(i));
    return data[i] + (data[j] - data[i]) * f;
}
void Engine::fillSourceWindow(const Voice& v) {
    const bool oneShot = settings_.mode == Mode::OneShot || settings_.mode == Mode::ReverseOneShot;
    const bool pingPong = settings_.mode == Mode::PingPong;
    constexpr int half = PitchShifter::windowSize / 2;
    // The streaming OLA frame corresponds to the previous window of output time.
    // Its centre follows transport, while adjacent samples retain natural spacing.
    double centre = v.position - v.direction * v.step * half;
    int frameDirection = v.direction;
    if (pingPong) {
        double span = hi - lo - 1, phase = std::fmod(centre - lo, 2 * span);
        if (phase < 0) phase += 2 * span;
        if (phase > span) { phase = 2 * span - phase; frameDirection = -frameDirection; }
        centre = lo + phase;
    } else if (!oneShot) {
        centre = std::fmod(centre - lo, hi - lo); if (centre < 0) centre += hi - lo; centre += lo;
    }
    const double halfHop = v.step * PitchShifter::hopSize * .5;
    const double radius = v.sourceStep * half;
    if (halfHop > radius) {
        // At extreme compression, neighbouring natural-rate windows leave gaps.
        // Use the precomputed peak pyramid to move a window onto a stronger
        // attack within its transport interval instead of silently skipping it.
        auto strength = [&](double a, double b) {
            a = std::clamp(std::floor(a), lo, hi); b = std::clamp(std::ceil(b), lo, hi);
            if (b <= a) return 0.f;
            auto peak = sample->peak(static_cast<size_t>(a), static_cast<size_t>(b));
            return std::max(std::abs(peak.lo), std::abs(peak.hi));
        };
        float best = strength(centre - radius, centre + radius);
        double selected = centre;
        auto consider = [&](double a, double b) {
            a = std::clamp(std::floor(a), lo, hi); b = std::clamp(std::ceil(b), lo, hi);
            if (b <= a) return;
            float peak = strength(a, b);
            if (peak <= best * 1.01f + 1.e-6f) return;
            best = peak;
            while (b - a > 1) {
                double mid = std::floor((a + b) * .5);
                if (strength(a, mid) >= strength(mid, b)) b = mid; else a = mid;
            }
            selected = a;
        };
        if (oneShot || pingPong) consider(centre - halfHop, centre + halfHop);
        else if (halfHop * 2 >= hi - lo) consider(lo, hi);
        else {
            consider(centre - halfHop, centre + halfHop);
            if (centre - halfHop < lo) consider(hi - (lo - centre + halfHop), hi);
            if (centre + halfHop > hi) consider(lo, lo + centre + halfHop - hi);
        }
        centre = selected;
    }
    double cursor = centre - frameDirection * v.sourceStep * half;
    for (int i = 0; i < PitchShifter::sourceWindowSize; ++i, cursor += frameDirection * v.sourceStep) {
        double p = cursor;
        if (oneShot && (p < lo || p >= hi)) { sourceWindow[0][i] = sourceWindow[1][i] = 0; continue; }
        if (pingPong) {
            double span = hi - lo - 1, phase = std::fmod(p - lo, 2 * span);
            if (phase < 0) phase += 2 * span;
            p = lo + (phase <= span ? phase : 2 * span - phase);
        } else if (!oneShot && (p < lo || p >= hi)) {
            p = std::fmod(p - lo, hi - lo); if (p < 0) p += hi - lo; p += lo; cursor = p;
        }
        float edge = 1;
        if (fadeIn > 0) edge *= static_cast<float>(std::clamp((p - lo) / fadeIn, 0.0, 1.0));
        if (fadeOut > 0) edge *= static_cast<float>(std::clamp((hi - 1 - p) / fadeOut, 0.0, 1.0));
        sourceWindow[0][i] = read(sample->left, p, !oneShot && !pingPong) * edge;
        sourceWindow[1][i] = read(sample->right, p, !oneShot && !pingPong) * edge;
    }
}
void Engine::render(float& left, float& right) {
    left = right = 0;
    gain += (targetGain - gain) * static_cast<float>(1.0 / std::max(1.0, outputRate * .005));
    if (!sample || sample->frames() < 2) return;
    const bool oneShot = settings_.mode == Mode::OneShot || settings_.mode == Mode::ReverseOneShot;
    for (size_t index = 0; index < voices.size(); ++index) {
        auto& v = voices[index]; if (!v.active) continue;
        auto drain = [&] {
            v.draining = true;
            v.tailRemaining = !v.stretch && std::abs(v.pitchRatio - 1) < 1.e-7 ? PitchShifter::latency : PitchShifter::tail;
        };
        if (!v.draining && v.releasing) {
            v.envelope -= v.releaseStep;
            if (v.envelope <= 0) drain();
        } else if (!v.draining && v.envelope < 1) {
            v.envelope = std::min(1.f, v.envelope + static_cast<float>(1.0 / std::max(1.0, settings_.attackMs * .001 * outputRate)));
        }
        float l = 0, r = 0, spectralEnvelope = 0;
        if (!v.draining) {
            const bool wrap = !oneShot && settings_.mode != Mode::PingPong;
            l = read(sample->left, v.position, wrap); r = read(sample->right, v.position, wrap);
            float edge = 1;
            if (fadeIn > 0) edge *= static_cast<float>(std::clamp((v.position - lo) / fadeIn, 0.0, 1.0));
            if (fadeOut > 0) edge *= static_cast<float>(std::clamp((hi - 1 - v.position) / fadeOut, 0.0, 1.0));
            float ending = 1;
            if (oneShot) {
                double distance = v.direction > 0 ? hi - v.position : v.position - lo + 1;
                ending = static_cast<float>(std::min(1.0, distance / std::max(1.0, std::min(32.0, (hi - lo) / v.step / 4) * v.step)));
            }
            spectralEnvelope = v.envelope * v.velocity * ending;
            float level = spectralEnvelope * edge;
            l *= level; r *= level;
            v.position += v.step * v.direction;
            if (oneShot) {
                if (v.position >= hi || v.position < lo) drain();
            } else if (settings_.mode == Mode::PingPong) {
                const double span = hi - lo - 1, period = 2 * span;
                if (v.position > hi - 1 || v.position < lo) {
                    double phase = std::fmod(v.position - lo, period); if (phase < 0) phase += period;
                    const bool descending = phase > span;
                    v.position = lo + (descending ? period - phase : phase);
                    v.direction *= descending ? -1 : 1;
                }
            } else {
                const double length = hi - lo;
                if (v.direction > 0 && v.position >= hi) v.position = lo + std::fmod(v.position - hi, length);
                if (v.direction < 0 && v.position < lo) {
                    v.position = hi - std::fmod(lo - v.position, length);
                    if (v.position >= hi) v.position = lo;
                }
            }
        } else {
            if (--v.tailRemaining <= 0) v.active = false;
            // Keep the analysis centre advancing beyond a one-shot end so its
            // source windows drain to zero rather than repeating the last frame.
            if (v.stretch) v.position += v.direction * v.step;
        }
        const float* sourceLeft = nullptr; const float* sourceRight = nullptr;
        if (v.stretch && pitchShifter.needsSourceWindow(index)) {
            fillSourceWindow(v); sourceLeft = sourceWindow[0].data(); sourceRight = sourceWindow[1].data();
        }
        pitchShifter.process(index, l, r, v.stretch ? v.sourcePitch : v.pitchRatio,
                             v.stretch, sourceLeft, sourceRight, spectralEnvelope);
        left += l; right += r;
    }
    effects.process(left, right); left *= gain; right *= gain;
}
int Engine::activeCount() const { int count = 0; for (auto& v : voices) count += v.active; return count; }
int Engine::transportCount() const { int count = 0; for (auto& v : voices) count += v.active && !v.draining; return count; }
double Engine::playhead() const {
    const Voice* latest = nullptr;
    for (auto& v : voices) if (v.active && !v.draining && (!latest || v.age > latest->age)) latest = &v;
    return latest && sample ? latest->position / static_cast<double>(sample->frames()) : -1;
}
std::shared_ptr<Sample> makeDemo() {
    auto s = std::make_shared<Sample>(); s->name = "Glass Current — demo";
    const size_t count = 144000; s->left.resize(count); s->right.resize(count);
    constexpr double pi = 3.14159265358979323846;
    for (size_t i = 0; i < count; ++i) {
        double t = i / s->rate, pulse = std::fmod(t, .375);
        double env = (1 - std::exp(-pulse * 900)) * std::exp(-pulse * 12);
        double body = std::sin(2 * pi * 261.6256 * t) * .42 + std::sin(2 * pi * 523.2512 * t + .8 * std::sin(2 * pi * .7 * t)) * .22;
        double top = std::sin(2 * pi * 1046.5024 * t) * .12 * env;
        double edge = std::min({1.0, t * 80, (3 - t) * 80});
        s->left[i] = static_cast<float>((body * (.32 + .68 * env) + top) * edge);
        s->right[i] = static_cast<float>((body * (.32 + .68 * env) + std::sin(2 * pi * 1046.5024 * t + .12) * .12 * env) * edge);
    }
    s->buildPeaks(); return s;
}
} // namespace hasio
