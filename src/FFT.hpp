#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <vector>
#if defined(__APPLE__) && !defined(HASIO_PORTABLE_DSP)
#include <Accelerate/Accelerate.h>
#endif

namespace hasio {
namespace detail {
inline size_t checkedFFTSize(size_t size) {
    if (size < 2 || (size & (size - 1)) != 0)
        throw std::invalid_argument("FFT size must be a power of two of at least 2");
    return size;
}
}

// Split-complex radix-2 FFT. Allocate and precompute the plan once, before audio
// processing; transforms operate in place without allocation or synchronization.
// Both directions are unnormalized, matching vDSP_fft_zip: inverse(forward(x))
// is size * x. The caller owns normalization and any real-spectrum symmetry.
class PortableFFT {
    const size_t size_;
    std::vector<size_t> reversed_;
    std::vector<float> twiddleReal_, twiddleImaginary_;

    void transform(float* real, float* imaginary, bool inverse) const noexcept {
        for (size_t i = 0; i < size_; ++i) {
            const size_t other = reversed_[i];
            if (i < other) { std::swap(real[i], real[other]); std::swap(imaginary[i], imaginary[other]); }
        }
        for (size_t half = 1; half < size_; half *= 2) {
            const size_t width = half * 2, stride = size_ / width;
            for (size_t start = 0; start < size_; start += width) {
                for (size_t j = 0; j < half; ++j) {
                    const size_t index = j * stride, a = start + j, b = a + half;
                    const float wr = twiddleReal_[index];
                    const float wi = inverse ? -twiddleImaginary_[index] : twiddleImaginary_[index];
                    const float tr = wr * real[b] - wi * imaginary[b];
                    const float ti = wr * imaginary[b] + wi * real[b];
                    const float ar = real[a], ai = imaginary[a];
                    real[a] = ar + tr; imaginary[a] = ai + ti;
                    real[b] = ar - tr; imaginary[b] = ai - ti;
                }
            }
        }
    }
public:
    explicit PortableFFT(size_t size) : size_(detail::checkedFFTSize(size)), reversed_(size_),
        twiddleReal_(size_ / 2), twiddleImaginary_(size_ / 2) {
        for (size_t i = 1; i < size_; ++i)
            reversed_[i] = (reversed_[i / 2] >> 1) | ((i & 1) * (size_ / 2));
        constexpr double tau = 6.28318530717958647692;
        for (size_t i = 0; i < size_ / 2; ++i) {
            const double angle = -tau * i / size_;
            twiddleReal_[i] = static_cast<float>(std::cos(angle));
            twiddleImaginary_[i] = static_cast<float>(std::sin(angle));
        }
    }
    PortableFFT(const PortableFFT&) = delete;
    PortableFFT& operator=(const PortableFFT&) = delete;
    void forward(float* real, float* imaginary) const noexcept { transform(real, imaginary, false); }
    void inverse(float* real, float* imaginary) const noexcept { transform(real, imaginary, true); }
};

#if defined(__APPLE__) && !defined(HASIO_PORTABLE_DSP)
class FFT {
    vDSP_Length log2Size_ = 0;
    FFTSetup setup_;
public:
    explicit FFT(size_t size) {
        detail::checkedFFTSize(size);
        for (; size > 1; size >>= 1) ++log2Size_;
        setup_ = vDSP_create_fftsetup(log2Size_, kFFTRadix2);
        if (!setup_) throw std::runtime_error("Cannot initialize FFT");
    }
    ~FFT() { vDSP_destroy_fftsetup(setup_); }
    FFT(const FFT&) = delete;
    FFT& operator=(const FFT&) = delete;
    void forward(float* real, float* imaginary) const noexcept {
        DSPSplitComplex split{real, imaginary};
        vDSP_fft_zip(setup_, &split, 1, log2Size_, FFT_FORWARD);
    }
    void inverse(float* real, float* imaginary) const noexcept {
        DSPSplitComplex split{real, imaginary};
        vDSP_fft_zip(setup_, &split, 1, log2Size_, FFT_INVERSE);
    }
};
#else
using FFT = PortableFFT;
#endif
}
