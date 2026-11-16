#include "AudioFile.hpp"
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <FLAC/stream_decoder.h>

namespace hasio {
namespace {
struct FlacContext {
    std::shared_ptr<Sample> sample = std::make_shared<Sample>();
    std::string error;
};
FLAC__StreamDecoderWriteStatus flacWrite(const FLAC__StreamDecoder*, const FLAC__Frame* frame, const FLAC__int32* const buffers[], void* user) {
    auto& context = *static_cast<FlacContext*>(user); auto& s = *context.sample;
    auto& h = frame->header;
    if (h.channels < 1 || h.channels > 2 || h.sample_rate < 8000 || h.sample_rate > 384000 || h.bits_per_sample < 4 || h.bits_per_sample > 32 ||
        s.frames() + h.blocksize > maxSampleBytes / 8) {
        context.error = "Unsupported FLAC format or sample exceeds 192 MB."; return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
    }
    try {
        s.rate = h.sample_rate;
        double scale = std::ldexp(1.0, 1 - static_cast<int>(h.bits_per_sample));
        for (uint32_t i = 0; i < h.blocksize; ++i) {
            s.left.push_back(static_cast<float>(buffers[0][i] * scale));
            s.right.push_back(static_cast<float>(buffers[h.channels - 1][i] * scale));
        }
    } catch (...) { context.error = "Not enough memory to decode FLAC."; return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT; }
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}
void flacMetadata(const FLAC__StreamDecoder*, const FLAC__StreamMetadata* metadata, void* user) {
    if (metadata->type != FLAC__METADATA_TYPE_STREAMINFO) return;
    auto& c = *static_cast<FlacContext*>(user);
    auto n = metadata->data.stream_info.total_samples;
    if (n > maxSampleBytes / 8) { c.error = "Sample exceeds 192 MB."; return; }
    try { c.sample->left.reserve(n); c.sample->right.reserve(n); } catch (...) { c.error = "Not enough memory to decode FLAC."; }
}
void flacError(const FLAC__StreamDecoder*, FLAC__StreamDecoderErrorStatus, void* user) {
    static_cast<FlacContext*>(user)->error = "The FLAC file is damaged or incomplete.";
}
std::shared_ptr<Sample> loadFlac(const std::string& path, std::string& error) {
    FlacContext context;
    auto* decoder = FLAC__stream_decoder_new();
    if (!decoder) { error = "Cannot create FLAC decoder."; return {}; }
    FLAC__stream_decoder_set_md5_checking(decoder, true);
    auto init = FLAC__stream_decoder_init_file(decoder, path.c_str(), flacWrite, flacMetadata, flacError, &context);
    bool ok = init == FLAC__STREAM_DECODER_INIT_STATUS_OK && FLAC__stream_decoder_process_until_end_of_stream(decoder);
    bool checksum = FLAC__stream_decoder_finish(decoder); FLAC__stream_decoder_delete(decoder);
    if (!ok || !checksum || !context.error.empty() || context.sample->frames() < 2) {
        error = context.error.empty() ? "Cannot decode this FLAC file." : context.error; return {};
    }
    auto s = context.sample; s->name = [[NSString stringWithUTF8String:path.c_str()] lastPathComponent].UTF8String;
    s->buildPeaks(); return s;
}
}
std::shared_ptr<Sample> loadAudioFile(const std::string& path, std::string& error) {
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path.c_str()]];
        if ([url.pathExtension.lowercaseString isEqualToString:@"flac"]) return loadFlac(path, error);
        ExtAudioFileRef file = nullptr;
        if (ExtAudioFileOpenURL((__bridge CFURLRef)url, &file) != noErr) {
            error = "Cannot open audio. Choose a WAV, AIFF or FLAC file."; return {};
        }
        struct Closer { ExtAudioFileRef f; ~Closer() { ExtAudioFileDispose(f); } } closer{file};
        AudioStreamBasicDescription source{}; UInt32 sz = sizeof(source);
        SInt64 frames = 0; UInt32 framesSize = sizeof(frames);
        if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &sz, &source) != noErr ||
            ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames) != noErr ||
            frames < 2 || source.mChannelsPerFrame < 1 || source.mChannelsPerFrame > 2 ||
            !std::isfinite(source.mSampleRate) || source.mSampleRate < 8000 || source.mSampleRate > 384000) {
            error = "Use mono or stereo audio, 8–384 kHz."; return {};
        }
        if (static_cast<uint64_t>(frames) > maxSampleBytes / 8) {
            error = "This sample is too large (maximum 192 MB decoded stereo audio)."; return {};
        }
        AudioStreamBasicDescription format{};
        format.mSampleRate = source.mSampleRate; format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
        format.mBitsPerChannel = 32; format.mChannelsPerFrame = source.mChannelsPerFrame;
        format.mFramesPerPacket = 1; format.mBytesPerFrame = format.mBytesPerPacket = 4 * source.mChannelsPerFrame;
        if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof(format), &format) != noErr) {
            error = "Audio format conversion failed."; return {};
        }
        try {
            auto s = std::make_shared<Sample>(); s->rate = source.mSampleRate;
            s->name = url.lastPathComponent.UTF8String;
            s->left.resize(frames); s->right.resize(frames);
            std::array<float, 8192> scratch{}; size_t offset = 0;
            while (offset < static_cast<size_t>(frames)) {
                UInt32 count = static_cast<UInt32>(std::min<size_t>(4096, frames - offset));
                AudioBufferList buffers{}; buffers.mNumberBuffers = 1;
                buffers.mBuffers[0] = {source.mChannelsPerFrame, count * format.mBytesPerFrame, scratch.data()};
                if (ExtAudioFileRead(file, &count, &buffers) != noErr) { error = "Audio decoding failed."; return {}; }
                if (!count) break;
                for (UInt32 i = 0; i < count; ++i) {
                    float l = scratch[i * source.mChannelsPerFrame];
                    float r = scratch[i * source.mChannelsPerFrame + source.mChannelsPerFrame - 1];
                    s->left[offset + i] = std::isfinite(l) ? std::clamp(l, -32.f, 32.f) : 0;
                    s->right[offset + i] = std::isfinite(r) ? std::clamp(r, -32.f, 32.f) : 0;
                }
                offset += count;
            }
            if (offset < 2) { error = "The file contains no playable audio."; return {}; }
            s->left.resize(offset); s->right.resize(offset); s->buildPeaks(); return s;
        } catch (...) { error = "Not enough memory to load this sample."; return {}; }
    }
}
}
