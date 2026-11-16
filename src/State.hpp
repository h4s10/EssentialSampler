#pragma once
#include "Engine.hpp"
#include <cstring>
#include <stdexcept>

namespace hasio {
// v2: magic/version, parameter count, normalized float64 parameters, sample rate,
// frame count, UTF-8 name length/name, then interleaved stereo float32 PCM.
// v1 had exactly 9 parameters and no count. Preserve its parameter IDs.
inline std::vector<uint8_t> saveState(const Model& m) {
    std::vector<uint8_t> out;
    auto s = m.samples.snapshot();
    out.reserve(128 + (s ? s->frames() * 8 : 0));
    auto put = [&](const auto& v) { auto p = reinterpret_cast<const uint8_t*>(&v); out.insert(out.end(), p, p + sizeof(v)); };
    put(uint32_t(0x504c5348)); put(uint32_t(2)); put(uint32_t(ParamCount));
    for (auto& p : m.params) put(norm(p.load()));
    put(s ? s->rate : 48000.0); put(uint64_t(s ? s->frames() : 0));
    std::string name = s ? s->name.substr(0, 4096) : "";
    put(uint32_t(name.size())); out.insert(out.end(), name.begin(), name.end());
    if (s) for (size_t i = 0; i < s->frames(); ++i) { put(s->left[i]); put(s->right[i]); }
    return out;
}
inline bool loadState(Model& m, const uint8_t* bytes, size_t size) {
    if (!bytes || size > maxSampleBytes + 8192) return false;
    size_t pos = 0;
    auto read = [&](auto& v) {
        if (sizeof(v) > size - pos) throw std::runtime_error("Truncated state");
        std::memcpy(&v, bytes + pos, sizeof(v)); pos += sizeof(v);
    };
    try {
        uint32_t magic, version; read(magic); read(version);
        if (magic != 0x504c5348 || (version != 1 && version != 2)) return false;
        uint32_t count = 9;
        if (version == 2) { read(count); if (count != 12 && count != 15 && count != ParamCount) return false; }
        std::array<double, ParamCount> params{};
        std::copy_n(defaults, ParamCount, params.begin());
        for (uint32_t i = 0; i < count; ++i) { auto& p = params[i]; read(p); if (!std::isfinite(p) || p < 0 || p > 1) return false; }
        if (version == 1) {
            params[FadeIn] = params[FadeOut] = normalized(FadeIn, plain(LegacyCrossfade, params[LegacyCrossfade]));
            params[KeepSpeed] = 0;
        }
        auto s = std::make_shared<Sample>(); read(s->rate);
        uint64_t frames; uint32_t nameSize; read(frames); read(nameSize);
        if (!std::isfinite(s->rate) || s->rate < 8000 || s->rate > 384000 || frames > maxSampleBytes / 8 || (frames != 0 && frames < 2)) return false;
        if (nameSize > 4096 || nameSize > size - pos) return false;
        s->name.assign(reinterpret_cast<const char*>(bytes + pos), nameSize); pos += nameSize;
        if (frames * 8 != size - pos) return false;
        s->left.resize(frames); s->right.resize(frames);
        for (size_t i = 0; i < frames; ++i) {
            read(s->left[i]); read(s->right[i]);
            if (!std::isfinite(s->left[i]) || !std::isfinite(s->right[i])) return false;
        }
        s->buildPeaks();
        m.samples.publish(frames ? s : nullptr);
        for (uint32_t i = 0; i < ParamCount; ++i) m.params[i].store(params[i]);
        m.panic.store(true); m.setStatus(""); return true;
    } catch (...) { return false; }
}
} // namespace hasio
