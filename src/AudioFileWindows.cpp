#include "AudioFile.hpp"
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>

// No platform APIs are needed here: C++17 filesystem opens UTF-8 paths through
// native wide paths on Windows, and this decoder can also be tested on macOS.
#define DR_WAV_IMPLEMENTATION
#define DR_WAV_NO_STDIO
#include "dr_libs/dr_wav.h"
#define DR_FLAC_IMPLEMENTATION
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#include "dr_libs/dr_flac.h"

namespace hasio {
namespace {
constexpr uint64_t maxFrames = maxSampleBytes / (2 * sizeof(float));
constexpr const char* formatError = "Use mono or stereo WAV, AIFF or FLAC audio, 8-384 kHz.";
constexpr const char* damagedError = "The audio file is damaged or incomplete.";
constexpr const char* sizeError = "This sample is too large (maximum 192 MB decoded stereo audio).";

// All offsets are checked against the actual file before seeking. Decoders may
// probe past EOF; a failed probe must not wrap the offset or poison later reads.
struct File {
    std::ifstream stream;
    uint64_t size = 0, position = 0;
    bool ready = false, readError = false;
    explicit File(const std::filesystem::path& path) : stream(path, std::ios::binary | std::ios::ate) {
        if (!stream) return;
        const auto end = stream.tellg();
        if (end < 0) return;
        size = static_cast<uint64_t>(end);
        ready = seek(0);
    }
    bool seek(uint64_t offset) {
        if (offset > size || offset > static_cast<uint64_t>(std::numeric_limits<std::streamoff>::max())) return false;
        stream.clear(); stream.seekg(static_cast<std::streamoff>(offset), std::ios::beg);
        if (!stream) return false;
        position = offset; return true;
    }
    bool relative(int offset, unsigned origin) {
        const uint64_t base = origin == 0 ? 0 : origin == 1 ? position : size;
        const int64_t delta = offset;
        if (delta < 0) {
            const uint64_t distance = static_cast<uint64_t>(-delta);
            return distance <= base && seek(base - distance);
        }
        return static_cast<uint64_t>(delta) <= size - base && seek(base + static_cast<uint64_t>(delta));
    }
    size_t read(void* output, size_t count) {
        const auto amount = static_cast<size_t>(std::min<uint64_t>(size - position,
            std::min<uint64_t>(count, static_cast<uint64_t>(std::numeric_limits<std::streamsize>::max()))));
        if (!amount) return 0;
        stream.read(static_cast<char*>(output), static_cast<std::streamsize>(amount));
        const size_t got = static_cast<size_t>(stream.gcount());
        position += got;
        if (got != amount) readError = true;
        return got;
    }
    bool at(uint64_t offset, void* output, size_t count) { return seek(offset) && read(output, count) == count; }
};
size_t readFile(void* user, void* output, size_t count) { return static_cast<File*>(user)->read(output, count); }
drwav_bool32 seekWav(void* user, int offset, drwav_seek_origin origin) {
    return static_cast<File*>(user)->relative(offset, static_cast<unsigned>(origin));
}
drwav_bool32 tellWav(void* user, drwav_int64* position) {
    *position = static_cast<drwav_int64>(static_cast<File*>(user)->position); return DRWAV_TRUE;
}
drflac_bool32 seekFlac(void* user, int offset, drflac_seek_origin origin) {
    return static_cast<File*>(user)->relative(offset, static_cast<unsigned>(origin));
}
drflac_bool32 tellFlac(void* user, drflac_int64* position) {
    *position = static_cast<drflac_int64>(static_cast<File*>(user)->position); return DRFLAC_TRUE;
}
uint64_t number(const uint8_t* bytes, unsigned count, bool big) {
    uint64_t value = 0;
    for (unsigned i = 0; i < count; ++i) value = (value << 8) | bytes[big ? i : count - i - 1];
    return value;
}
bool tag(const uint8_t* bytes, const char* expected) { return std::memcmp(bytes, expected, 4) == 0; }
bool validFormat(unsigned channels, double rate, uint64_t frames, std::string& error, bool unknownLength = false) {
    if (channels < 1 || channels > 2 || !std::isfinite(rate) || rate < 8000 || rate > 384000) {
        error = formatError; return false;
    }
    if (frames > maxFrames) { error = sizeError; return false; }
    if (frames < 2 && !(unknownLength && frames == 0)) {
        error = "The file contains no playable audio."; return false;
    }
    return true;
}
float clean(double value) { return std::isfinite(value) ? static_cast<float>(std::clamp(value, -32.0, 32.0)) : 0; }
std::shared_ptr<Sample> allocateSample(uint64_t frames, double rate) {
    auto sample = std::make_shared<Sample>(); sample->rate = rate;
    sample->left.resize(static_cast<size_t>(frames)); sample->right.resize(static_cast<size_t>(frames));
    return sample;
}
template<typename T>
void copyFrames(Sample& sample, size_t offset, const T* source, size_t frames, unsigned channels) {
    for (size_t i = 0; i < frames; ++i) {
        sample.left[offset + i] = clean(source[i * channels]);
        sample.right[offset + i] = clean(source[i * channels + channels - 1]);
    }
}

// Validate the enclosing RIFF lengths before dr_wav can clamp a truncated data
// chunk to the physical file size. No allocation depends on these chunk sizes.
bool validateWav(File& file, const uint8_t* header, uint64_t& dataBytes, std::string& error) {
    const bool big = tag(header, "RIFX");
    const uint64_t end = number(header + 4, 4, big) + 8;
    if (!tag(header + 8, "WAVE") || end < 12 || end > file.size) { error = damagedError; return false; }
    bool format = false, data = false;
    for (uint64_t offset = 12; offset < end;) {
        uint8_t chunk[8];
        if (end - offset < sizeof(chunk) || !file.at(offset, chunk, sizeof(chunk))) { error = damagedError; return false; }
        const uint64_t length = number(chunk + 4, 4, big), start = offset + 8;
        const uint64_t padded = length + (length & 1);
        if (padded > end - start) { error = damagedError; return false; }
        if (tag(chunk, "fmt ")) {
            if (format || data || length < 16) { error = damagedError; return false; }
            format = true;
        } else if (tag(chunk, "data")) {
            if (!format || data) { error = damagedError; return false; }
            data = true; dataBytes = length;
        }
        offset = start + padded;
    }
    if (!format || !data) { error = damagedError; return false; }
    return file.seek(0);
}
std::shared_ptr<Sample> loadWav(File& file, const uint8_t* header, std::string& error) {
    uint64_t dataBytes = 0;
    if (!validateWav(file, header, dataBytes, error)) return {};
    drwav decoder{};
    if (!drwav_init(&decoder, readFile, seekWav, tellWav, &file, nullptr)) { error = damagedError; return {}; }
    struct Close { drwav* decoder; ~Close() { drwav_uninit(decoder); } } close{&decoder};
    const bool pcm = decoder.translatedFormatTag == DR_WAVE_FORMAT_PCM;
    const bool floating = decoder.translatedFormatTag == DR_WAVE_FORMAT_IEEE_FLOAT;
    const auto bits = decoder.bitsPerSample;
    if ((!pcm && !floating) || (pcm && bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
        (floating && bits != 32 && bits != 64) || decoder.fmt.blockAlign != decoder.channels * (bits / 8) ||
        decoder.fmt.blockAlign == 0 || decoder.dataChunkDataSize != dataBytes ||
        dataBytes % decoder.fmt.blockAlign != 0) {
        error = formatError; return {};
    }
    if (decoder.fmt.formatTag == DR_WAVE_FORMAT_EXTENSIBLE) {
        // The complete GUID distinguishes PCM/IEEE float from unrelated codecs.
        const uint8_t suffix[] = {0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71};
        if (std::memcmp(decoder.fmt.subFormat + 2, suffix, sizeof(suffix)) != 0 ||
            decoder.fmt.validBitsPerSample == 0 || decoder.fmt.validBitsPerSample > bits) {
            error = formatError; return {};
        }
    }
    if (!validFormat(decoder.channels, decoder.sampleRate, decoder.totalPCMFrameCount, error)) return {};
    auto sample = allocateSample(decoder.totalPCMFrameCount, decoder.sampleRate);
    std::array<float, 8192> scratch{};
    std::array<double, 8192> wideScratch{};
    for (size_t offset = 0; offset < sample->frames();) {
        const size_t count = std::min<size_t>(4096, sample->frames() - offset);
        if (floating && bits == 64) {
            // Keep finite doubles finite until clamping: conversion to float
            // first would turn very large finite samples into infinity/silence.
            if (drwav_read_pcm_frames(&decoder, count, wideScratch.data()) != count || file.readError) {
                error = damagedError; return {};
            }
            copyFrames(*sample, offset, wideScratch.data(), count, decoder.channels);
        } else {
            if (drwav_read_pcm_frames_f32(&decoder, count, scratch.data()) != count || file.readError) {
                error = damagedError; return {};
            }
            copyFrames(*sample, offset, scratch.data(), count, decoder.channels);
        }
        offset += count;
    }
    return sample;
}

double extendedRate(const uint8_t* bytes) {
    const auto exponent = number(bytes, 2, true);
    const auto significand = number(bytes + 2, 8, true);
    if ((exponent & 0x8000) || exponent == 0 || exponent == 0x7fff || !(significand & (uint64_t(1) << 63))) return 0;
    return std::ldexp(static_cast<double>(significand), static_cast<int>(exponent) - 16383 - 63);
}
std::shared_ptr<Sample> loadAiff(File& file, const uint8_t* header, std::string& error) {
    const bool compressed = tag(header + 8, "AIFC");
    const uint64_t end = number(header + 4, 4, true) + 8;
    if ((!compressed && !tag(header + 8, "AIFF")) || end < 12 || end > file.size) { error = damagedError; return {}; }
    uint64_t frames = 0, audioOffset = 0, audioBytes = 0;
    unsigned channels = 0, bits = 0;
    double rate = 0;
    bool haveFormat = false, haveAudio = false, big = true, floating = false;
    for (uint64_t offset = 12; offset < end;) {
        uint8_t chunk[8];
        if (end - offset < sizeof(chunk) || !file.at(offset, chunk, sizeof(chunk))) { error = damagedError; return {}; }
        const uint64_t length = number(chunk + 4, 4, true), start = offset + 8;
        const uint64_t padded = length + (length & 1);
        if (padded > end - start) { error = damagedError; return {}; }
        if (tag(chunk, "COMM")) {
            uint8_t comm[22]{}; const size_t needed = compressed ? 22 : 18;
            if (haveFormat || length < needed || !file.at(start, comm, needed)) { error = damagedError; return {}; }
            channels = static_cast<unsigned>(number(comm, 2, true));
            frames = number(comm + 2, 4, true); bits = static_cast<unsigned>(number(comm + 6, 2, true));
            rate = extendedRate(comm + 8); haveFormat = true;
            if (compressed) {
                if (tag(comm + 18, "sowt")) big = false;
                else if (tag(comm + 18, "fl32") || tag(comm + 18, "FL32")) floating = bits == 32;
                else if (tag(comm + 18, "fl64") || tag(comm + 18, "FL64")) floating = bits == 64;
                else if (!tag(comm + 18, "NONE") && !tag(comm + 18, "twos")) { error = formatError; return {}; }
                if (!floating && (tag(comm + 18, "fl32") || tag(comm + 18, "FL32") || tag(comm + 18, "fl64") || tag(comm + 18, "FL64"))) {
                    error = formatError; return {};
                }
            }
        } else if (tag(chunk, "SSND")) {
            uint8_t sound[8];
            if (haveAudio || length < sizeof(sound) || !file.at(start, sound, sizeof(sound))) { error = damagedError; return {}; }
            const uint64_t displacement = number(sound, 4, true);
            if (displacement > length - 8) { error = damagedError; return {}; }
            audioOffset = start + 8 + displacement; audioBytes = length - 8 - displacement; haveAudio = true;
        }
        offset = start + padded;
    }
    if (!haveFormat || !haveAudio) { error = damagedError; return {}; }
    if ((!floating && (bits < 1 || bits > 32)) || !validFormat(channels, rate, frames, error)) {
        if (error.empty()) error = formatError;
        return {};
    }
    const unsigned bytesPerSample = (bits + 7) / 8, bytesPerFrame = bytesPerSample * channels;
    // frames is already bounded, so multiplication cannot overflow.
    if (frames * bytesPerFrame > audioBytes || !file.seek(audioOffset)) { error = damagedError; return {}; }
    auto sample = allocateSample(frames, rate);
    std::array<uint8_t, 65536> scratch{};
    const auto decode = [&](const uint8_t* input) {
        const uint64_t value = number(input, bytesPerSample, big);
        if (floating) {
            if (bits == 32) { const uint32_t word = static_cast<uint32_t>(value); float f; std::memcpy(&f, &word, sizeof(f)); return clean(f); }
            double d; std::memcpy(&d, &value, sizeof(d)); return clean(d);
        }
        const unsigned storedBits = bytesPerSample * 8;
        const int64_t signedValue = value & (uint64_t(1) << (storedBits - 1))
            ? static_cast<int64_t>(value) - static_cast<int64_t>(uint64_t(1) << storedBits) : static_cast<int64_t>(value);
        return static_cast<float>(std::ldexp(static_cast<double>(signedValue), 1 - static_cast<int>(storedBits)));
    };
    for (size_t offset = 0; offset < sample->frames();) {
        const size_t count = std::min<size_t>(4096, sample->frames() - offset);
        if (file.read(scratch.data(), count * bytesPerFrame) != count * bytesPerFrame) { error = damagedError; return {}; }
        for (size_t i = 0; i < count; ++i) {
            sample->left[offset + i] = decode(scratch.data() + i * bytesPerFrame);
            sample->right[offset + i] = decode(scratch.data() + i * bytesPerFrame + (channels - 1) * bytesPerSample);
        }
        offset += count;
    }
    return sample;
}

bool validateFlac(File& file, std::string& error) {
    bool first = true;
    for (uint64_t offset = 4;;) {
        uint8_t metadata[4];
        if (!file.at(offset, metadata, sizeof(metadata))) { error = damagedError; return false; }
        const uint64_t length = number(metadata + 1, 3, true), start = offset + 4;
        const unsigned type = metadata[0] & 0x7f;
        if (length > file.size - start || type == 127 || (first && (type != 0 || length != 34)) || (!first && type == 0)) {
            error = damagedError; return false;
        }
        if (first) {
            uint8_t info[34];
            if (!file.at(start, info, sizeof(info))) { error = damagedError; return false; }
            const uint64_t packed = number(info + 10, 8, true);
            const auto channels = static_cast<unsigned>(((packed >> 41) & 7) + 1);
            const auto rate = static_cast<unsigned>(packed >> 44);
            const auto bits = static_cast<unsigned>(((packed >> 36) & 31) + 1);
            if (bits < 4 || !validFormat(channels, rate, packed & 0xfffffffffull, error, true)) {
                if (error.empty()) error = formatError;
                return false;
            }
            first = false;
        }
        if (metadata[0] & 0x80) return file.seek(0);
        offset = start + length;
    }
}
bool flacAtEnd(const drflac& decoder, const File& file) {
    // dr_flac's public read API reports both damaged frames and EOF as zero,
    // and skips frames with a bad CRC. Its pinned bitstream state lets us test
    // EOF *before* attempting a new block, including bytes buffered past the
    // physical file cursor. Keep the multiblock corruption tests when updating
    // dr_flac: checking only the underlying file position is insufficient.
    const auto& bits = decoder.bs;
    return file.position == file.size && bits.unalignedByteCount == 0 &&
        bits.consumedBits == sizeof(bits.cache) * 8 &&
        bits.nextL2Line == sizeof(bits.cacheL2) / sizeof(bits.cacheL2[0]);
}
std::shared_ptr<Sample> loadFlac(File& file, std::string& error) {
    if (!validateFlac(file, error)) return {};
    std::unique_ptr<drflac, decltype(&drflac_close)> decoder(drflac_open(readFile, seekFlac, tellFlac, &file, nullptr), drflac_close);
    if (!decoder) { error = damagedError; return {}; }
    if (!validFormat(decoder->channels, decoder->sampleRate, decoder->totalPCMFrameCount, error, true)) return {};
    const uint64_t declared = decoder->totalPCMFrameCount;
    auto sample = allocateSample(declared, decoder->sampleRate);
    std::array<float, 8192> scratch{};
    uint64_t offset = 0;
    for (;;) {
        const bool newBlock = decoder->currentFLACFrame.pcmFramesRemaining == 0;
        if (newBlock && flacAtEnd(*decoder, file)) break;
        // Never cross a block boundary in one public read. Otherwise a failed
        // next block can look like a successful partial read followed by EOF.
        const uint64_t count = newBlock ? 1 : std::min<uint64_t>(4096, decoder->currentFLACFrame.pcmFramesRemaining);
        const uint64_t got = drflac_read_pcm_frames_f32(decoder.get(), count, scratch.data());
        if (got != count || file.readError) { error = damagedError; return {}; }
        if (newBlock) {
            const auto& header = decoder->currentFLACFrame.header;
            const uint64_t first = header.pcmFrameNumber ? header.pcmFrameNumber
                : uint64_t(header.flacFrameNumber) * decoder->maxBlockSizeInPCMFrames;
            if (first != offset) { error = damagedError; return {}; }
        }
        const uint64_t limit = declared ? declared : maxFrames;
        if (got > limit - offset) { error = declared ? damagedError : sizeError; return {}; }
        if (!declared) {
            sample->left.resize(static_cast<size_t>(offset + got)); sample->right.resize(static_cast<size_t>(offset + got));
        }
        copyFrames(*sample, static_cast<size_t>(offset), scratch.data(), static_cast<size_t>(got), decoder->channels);
        offset += got;
    }
    if (offset < 2 || (declared && offset != declared)) { error = damagedError; return {}; }
    return sample;
}
}

std::shared_ptr<Sample> loadAudioFile(const std::string& path, std::string& error) {
    error.clear();
    try {
        if (path.empty() || path.find('\0') != std::string::npos) { error = "Cannot open this audio file."; return {}; }
        const auto nativePath = std::filesystem::u8path(path);
        File file(nativePath);
        if (!file.ready) { error = "Cannot open this audio file."; return {}; }
        uint8_t header[12]{};
        const auto headerSize = file.read(header, sizeof(header));
        std::shared_ptr<Sample> sample;
        if (headerSize >= 4 && tag(header, "fLaC")) sample = loadFlac(file, error);
        else if (headerSize == sizeof(header) && (tag(header, "RIFF") || tag(header, "RIFX"))) sample = loadWav(file, header, error);
        else if (headerSize == sizeof(header) && tag(header, "FORM")) sample = loadAiff(file, header, error);
        else error = formatError;
        if (!sample) return {};
        sample->name = nativePath.filename().u8string(); sample->buildPeaks(); return sample;
    } catch (const std::bad_alloc&) { error = "Not enough memory to load this sample."; return {}; }
      catch (const std::exception&) { error = "Cannot open or decode this audio file."; return {}; }
}
}
