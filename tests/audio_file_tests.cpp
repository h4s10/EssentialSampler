#include "AudioFile.hpp"
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
using Bytes = std::vector<uint8_t>;
namespace fs = std::filesystem;

void require(bool value, const std::string& message) {
    if (!value) throw std::runtime_error(message);
}
void integer(Bytes& bytes, uint64_t value, unsigned count, bool big = false) {
    for (unsigned i = 0; i < count; ++i)
        bytes.push_back(static_cast<uint8_t>(value >> (8 * (big ? count - i - 1 : i))));
}
void setInteger(Bytes& bytes, size_t at, uint64_t value, unsigned count, bool big = false) {
    Bytes encoded; integer(encoded, value, count, big);
    std::copy(encoded.begin(), encoded.end(), bytes.begin() + at);
}
void tag(Bytes& bytes, const char* text) { bytes.insert(bytes.end(), text, text + 4); }
void chunk(Bytes& bytes, const char* name, const Bytes& payload, bool big = false) {
    tag(bytes, name); integer(bytes, payload.size(), 4, big);
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    if (payload.size() & 1) bytes.push_back(0);
}
Bytes pcm(std::initializer_list<int32_t> samples, unsigned bits, bool big = false) {
    Bytes result;
    for (auto value : samples) integer(result, static_cast<uint32_t>(value), bits / 8, big);
    return result;
}
Bytes floats(std::initializer_list<double> samples, unsigned bits, bool big = false) {
    Bytes result;
    for (auto value : samples) {
        uint64_t encoded = 0;
        if (bits == 32) {
            float f = static_cast<float>(value); uint32_t word;
            std::memcpy(&word, &f, sizeof(word)); encoded = word;
        } else std::memcpy(&encoded, &value, sizeof(encoded));
        integer(result, encoded, bits / 8, big);
    }
    return result;
}
Bytes wav(const Bytes& data, unsigned bits = 16, unsigned channels = 1,
          unsigned rate = 48000, unsigned format = 1, bool extensible = false, bool big = false) {
    Bytes result; tag(result, big ? "RIFX" : "RIFF"); integer(result, 0, 4); tag(result, "WAVE");
    Bytes fmt; integer(fmt, extensible ? 0xfffe : format, 2, big); integer(fmt, channels, 2, big);
    integer(fmt, rate, 4, big); integer(fmt, rate * channels * (bits / 8), 4, big);
    integer(fmt, channels * (bits / 8), 2, big); integer(fmt, bits, 2, big);
    if (extensible) {
        integer(fmt, 22, 2); integer(fmt, bits, 2); integer(fmt, channels == 1 ? 4 : 3, 4);
        integer(fmt, format, 4); integer(fmt, 0, 2); integer(fmt, 0x10, 2);
        const uint8_t guid[] = {0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71};
        fmt.insert(fmt.end(), std::begin(guid), std::end(guid));
    }
    chunk(result, "fmt ", fmt, big); chunk(result, "JUNK", {1, 2, 3}, big); chunk(result, "data", data, big);
    setInteger(result, 4, result.size() - 8, 4, big); return result;
}
Bytes aiff(const Bytes& data, unsigned bits = 16, unsigned channels = 1,
           uint32_t frames = 4, unsigned rate = 48000, const char* compression = nullptr,
           unsigned offset = 0) {
    Bytes result; tag(result, "FORM"); integer(result, 0, 4); tag(result, compression ? "AIFC" : "AIFF");
    Bytes comm; integer(comm, channels, 2, true); integer(comm, frames, 4, true); integer(comm, bits, 2, true);
    // Canonical IEEE extended 80-bit representation, generated independently of the loader.
    int exponent; double fraction = std::frexp(rate, &exponent);
    integer(comm, exponent + 16382, 2, true);
    integer(comm, static_cast<uint64_t>(std::ldexp(fraction, 64)), 8, true);
    if (compression) { tag(comm, compression); comm.push_back(0); comm.push_back(0); }
    chunk(result, "COMM", comm, true); chunk(result, "ANNO", {1, 2, 3}, true);
    Bytes ssnd; integer(ssnd, offset, 4, true); integer(ssnd, 0, 4, true);
    ssnd.resize(ssnd.size() + offset, 0x55); ssnd.insert(ssnd.end(), data.begin(), data.end());
    chunk(result, "SSND", ssnd, true); setInteger(result, 4, result.size() - 8, 4, true);
    return result;
}
Bytes hex(const char* text) {
    Bytes result;
    auto digit = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
    for (size_t i = 0; text[i]; i += 2) result.push_back(static_cast<uint8_t>(digit(text[i]) * 16 + digit(text[i + 1])));
    return result;
}
// Independently encoded with reference libFLAC 1.5.0, --no-padding --no-seektable.
// Four stereo frames: (-1,.5), (-.5,-.25), (0,0), (32767/32768,.25).
Bytes flacStereo() {
    return hex("664c614300000022100010000000170000170bb802f000000004565685826f5d56c311540f9fe3ca662b"
               "84000028200000007265666572656e6365206c6962464c414320312e352e3020323032353032313100000000"
               "fff86a1800038c028000c00000007fff03000ae080eefe");
}
Bytes flacMono() {
    return hex("664c614300000022100010000000120000120ac440f0000000040b8c0c7169e43998bbad4467d63603ad"
               "84000028200000007265666572656e6365206c6962464c414320312e352e3020323032353032313100000000"
               "fff86908000314028000c00000007fff5e84");
}

struct Fixtures {
    fs::path directory = fs::temp_directory_path() / ("hasio-audio-tests-" +
        std::to_string(std::chrono::high_resolution_clock::now().time_since_epoch().count()));
    Fixtures() { fs::create_directories(directory); }
    ~Fixtures() { std::error_code error; fs::remove_all(directory, error); }
    std::string write(const Bytes& bytes, const std::string& name = "audio.bin") {
        auto path = directory / fs::u8path(name);
        std::ofstream file(path, std::ios::binary);
        file.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        require(file.good(), "Could not create test fixture"); file.close(); return path.u8string();
    }
    std::shared_ptr<hasio::Sample> decode(const Bytes& bytes, const std::string& name = "audio.bin") {
        std::string error = "stale error";
        auto sample = hasio::loadAudioFile(write(bytes, name), error);
        require(sample != nullptr, "Decode failed: " + error);
        require(error.empty(), "Successful decode left a stale error");
        require(!sample->peaks.empty(), "Decoded sample has no waveform peaks");
        return sample;
    }
    void reject(const Bytes& bytes) {
        std::string error;
        require(!hasio::loadAudioFile(write(bytes), error), "Invalid audio was accepted");
        require(!error.empty(), "Rejected audio has no error message");
    }
};
void channels(const hasio::Sample& sample, std::initializer_list<float> left,
              std::initializer_list<float> right, double rate = 48000) {
    require(sample.frames() == left.size() && sample.right.size() == right.size(), "Wrong decoded length");
    require(sample.rate == rate, "Wrong sample rate");
    size_t i = 0;
    for (float value : left) require(std::abs(sample.left[i++] - value) < 0.000001f, "Wrong left sample");
    i = 0;
    for (float value : right) require(std::abs(sample.right[i++] - value) < 0.000001f, "Wrong right sample");
}
}

int main() {
    Fixtures f;
    int failures = 0;
    auto test = [&](const char* name, const std::function<void()>& body) {
        try { body(); std::cout << "PASS " << name << '\n'; }
        catch (const std::exception& e) { ++failures; std::cerr << "FAIL " << name << ": " << e.what() << '\n'; }
    };
    test("WAV mono PCM16 duplicates channels and builds waveform", [&] {
        auto s = f.decode(wav(pcm({-32768, -16384, 0, 32767}, 16)));
        channels(*s, {-1, -.5f, 0, 32767.f / 32768}, {-1, -.5f, 0, 32767.f / 32768});
        require(s->peaks[0][0].lo == -1 && s->peaks[0][0].hi > .99f, "Wrong waveform peak range");
    });
    test("WAV stereo PCM24 preserves channel ordering", [&] {
        auto s = f.decode(wav(pcm({-8388608, 4194304, -4194304, -2097152, 0, 0, 8388607, 2097152}, 24), 24, 2));
        channels(*s, {-1, -.5f, 0, 8388607.f / 8388608}, {.5f, -.25f, 0, .25f});
    });
    test("WAV unsigned PCM8 and signed PCM32 scale correctly", [&] {
        channels(*f.decode(wav({0, 64, 128, 192}, 8)), {-1, -.5f, 0, .5f}, {-1, -.5f, 0, .5f});
        channels(*f.decode(wav(pcm({INT32_MIN, -1073741824, 0, 1073741824}, 32), 32)),
                 {-1, -.5f, 0, .5f}, {-1, -.5f, 0, .5f});
    });
    test("WAV extensible PCM and floating point decode", [&] {
        channels(*f.decode(wav(pcm({-32768, 16384, 0, 0}, 16), 16, 2, 48000, 1, true)), {-1, 0}, {.5f, 0});
        channels(*f.decode(wav(floats({-.5, .25, .75, -1}, 32), 32, 2, 48000, 3, true)), {-.5f, .75f}, {.25f, -1});
    });
    test("WAV float32 and float64 sanitize nonfinite samples and clamp gain", [&] {
        for (unsigned bits : {32u, 64u}) {
            auto s = f.decode(wav(floats({std::numeric_limits<double>::quiet_NaN(), INFINITY, -INFINITY, 33, -50, .125}, bits), bits, 1, 48000, 3));
            channels(*s, {0, 0, 0, 32, -32, .125f}, {0, 0, 0, 32, -32, .125f});
        }
    });
    test("Finite float64 extremes clamp before narrowing to float32", [&] {
        const double largest = std::numeric_limits<double>::max();
        for (bool big : {false, true}) {
            auto s = f.decode(wav(floats({largest, -largest}, 64, big), 64, 1, 48000, 3, false, big));
            channels(*s, {32, -32}, {32, -32});
        }
        channels(*f.decode(aiff(floats({largest, -largest}, 64, true), 64, 1, 2, 48000, "fl64")), {32, -32}, {32, -32});
    });
    test("RIFX big endian WAV PCM preserves stereo sample ordering", [&] {
        channels(*f.decode(wav(pcm({-32768, 16384, 0, -8192}, 16, true), 16, 2, 48000, 1, false, true)), {-1, 0}, {.5f, -.25f});
    });
    test("UTF-8 file path and display name survive decoding", [&] {
        const std::string name = u8"\u0411\u0430\u0440\u0430\u0431\u0430\u043d_\u97f3\u697d_\U0001f3b5.WAV";
        auto s = f.decode(wav(pcm({0, 16384}, 16)), name);
        require(s->name == name, "UTF-8 filename changed");
    });
    test("AIFF signed big endian PCM8/16/24/32 and SSND offset decode", [&] {
        for (unsigned bits : {8u, 16u, 24u, 32u}) {
            const int32_t half = static_cast<int32_t>(uint32_t(1) << (bits - 2));
            auto s = f.decode(aiff(pcm({-half, half, 0, -half}, bits, true), bits, 1, 4, 44100, nullptr, 3));
            channels(*s, {-.5f, .5f, 0, -.5f}, {-.5f, .5f, 0, -.5f}, 44100);
        }
    });
    test("AIFF stereo and AIFC little endian PCM decode", [&] {
        channels(*f.decode(aiff(pcm({-32768, 16384, 0, -8192}, 16, true), 16, 2, 2)), {-1, 0}, {.5f, -.25f});
        channels(*f.decode(aiff(pcm({-32768, 16384, 0, -8192}, 16), 16, 2, 2, 48000, "sowt")), {-1, 0}, {.5f, -.25f});
    });
    test("AIFC float32 and float64 decode and sanitize", [&] {
        for (unsigned bits : {32u, 64u}) {
            channels(*f.decode(aiff(floats({-.5, INFINITY, 40, .25}, bits, true), bits, 1, 4, 48000, bits == 32 ? "fl32" : "fl64")),
                     {-.5f, 0, 32, .25f}, {-.5f, 0, 32, .25f});
        }
    });
    test("FLAC stereo and mono decode exact independent fixtures", [&] {
        channels(*f.decode(flacStereo()), {-1, -.5f, 0, 32767.f / 32768}, {.5f, -.25f, 0, .25f});
        channels(*f.decode(flacMono()), {-1, -.5f, 0, 32767.f / 32768}, {-1, -.5f, 0, 32767.f / 32768}, 44100);
    });
    test("FLAC with unknown total frame count decodes to EOF", [&] {
        auto bytes = flacStereo(); setInteger(bytes, 18, (uint64_t(48000) << 44) | (uint64_t(1) << 41) | (uint64_t(15) << 36), 8, true);
        channels(*f.decode(bytes), {-1, -.5f, 0, 32767.f / 32768}, {.5f, -.25f, 0, .25f});
    });
    test("8 kHz and 384 kHz limits are accepted", [&] {
        for (unsigned rate : {8000u, 384000u}) {
            channels(*f.decode(wav(pcm({0, 0}, 16), 16, 1, rate)), {0, 0}, {0, 0}, rate);
            channels(*f.decode(aiff(pcm({0, 0}, 16), 16, 1, 2, rate)), {0, 0}, {0, 0}, rate);
        }
    });
    test("Unsupported rates and channel counts are rejected", [&] {
        for (unsigned rate : {0u, 7999u, 384001u, 0xffffffffu}) f.reject(wav(pcm({0, 0, 0, 0}, 16), 16, 1, rate));
        for (unsigned count : {0u, 3u, 65535u}) f.reject(wav(pcm({0, 0, 0, 0}, 16), 16, count));
        f.reject(aiff(pcm({0, 0, 0, 0}, 16), 16, 3, 2));
        f.reject(aiff(pcm({0, 0, 0, 0}, 16), 16, 1, 4, 7999));
        auto bytes = flacStereo(); setInteger(bytes, 18, (uint64_t(7999) << 44) | (uint64_t(1) << 41) | (uint64_t(15) << 36) | 4, 8, true); f.reject(bytes);
        bytes = flacStereo(); bytes[20] |= 0xe; f.reject(bytes);
    });
    test("Empty and one-frame samples are rejected", [&] {
        f.reject(wav({})); f.reject(wav(pcm({1}, 16)));
        f.reject(aiff({}, 16, 1, 0)); f.reject(aiff(pcm({1}, 16), 16, 1, 1));
        auto bytes = flacStereo(); bytes.resize(86); f.reject(bytes);
    });
    test("Unknown and truncated container headers are rejected", [&] {
        f.reject({}); f.reject({'N', 'O', 'P', 'E'});
        for (const auto& bytes : {wav(pcm({0, 0}, 16)), aiff(pcm({0, 0, 0, 0}, 16)), flacStereo()}) {
            for (size_t size : {size_t(3), size_t(11), size_t(25), bytes.size() - 1})
                f.reject(Bytes(bytes.begin(), bytes.begin() + std::min(size, bytes.size() - 1)));
        }
    });
    test("Malformed WAV chunks and partial PCM frames are rejected", [&] {
        auto bytes = wav(pcm({0, 0}, 16)); setInteger(bytes, 16, 0xffffffff, 4); f.reject(bytes);
        bytes = wav(pcm({0, 0}, 16)); setInteger(bytes, 4, 11, 4); f.reject(bytes);
        bytes = wav(pcm({0, 0}, 16)); setInteger(bytes, 32, 0, 2); f.reject(bytes);
        f.reject(wav({0, 0, 0, 0, 0}, 16));
        f.reject(wav(pcm({0, 0}, 16), 16, 1, 48000, 6));
    });
    test("Malformed AIFF length, extended rate, offset and compression are rejected", [&] {
        auto bytes = aiff(pcm({0, 0, 0, 0}, 16)); setInteger(bytes, 16, 0xffffffff, 4, true); f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); setInteger(bytes, 22, 5, 4, true); f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); bytes[28] = 0x7f; bytes[29] = 0xff; f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); bytes[28] |= 0x80; f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); bytes[30] = 0; f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); setInteger(bytes, 58, 0xffffffff, 4, true); f.reject(bytes);
        f.reject(aiff(pcm({0, 0, 0, 0}, 16), 16, 1, 4, 48000, "ima4"));
    });
    test("Oversized declared audio is rejected before decoding", [&] {
        auto bytes = wav(pcm({0, 0}, 16)); setInteger(bytes, 52, 0xfffffff0, 4); f.reject(bytes);
        bytes = aiff(pcm({0, 0, 0, 0}, 16)); setInteger(bytes, 22, hasio::maxSampleBytes / 8 + 1, 4, true); f.reject(bytes);
        bytes = flacStereo(); setInteger(bytes, 18, (uint64_t(48000) << 44) | (uint64_t(1) << 41) | (uint64_t(15) << 36) | (hasio::maxSampleBytes / 8 + 1), 8, true); f.reject(bytes);
    });
    test("FLAC truncated metadata and damaged frame CRC are rejected", [&] {
        auto bytes = flacStereo(); bytes[5] = 0x7f; f.reject(bytes);
        bytes = flacStereo(); bytes[43] = 0x7f; f.reject(bytes);
        bytes = flacStereo(); bytes.back() ^= 0x10; f.reject(bytes);
        bytes = flacStereo(); bytes[101] ^= 0x20; f.reject(bytes);
    });
    test("Missing files and embedded NUL paths produce errors", [&] {
        std::string error;
        require(!hasio::loadAudioFile((f.directory / "missing.wav").u8string(), error) && !error.empty(), "Missing file accepted");
        std::string path = f.write(wav(pcm({0, 0}, 16))); path += '\0'; path += "ignored";
        error.clear(); require(!hasio::loadAudioFile(path, error) && !error.empty(), "Embedded NUL path accepted");
    });
    if (failures) std::cerr << failures << " audio file test(s) failed\n";
    return failures ? 1 : 0;
}
