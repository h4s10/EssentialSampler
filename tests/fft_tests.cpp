#include "FFT.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <new>
#include <stdexcept>
#include <vector>

namespace {
size_t allocationCount = 0;
constexpr double tau = 6.28318530717958647692;
void require(bool condition, const char* message) {
    if (!condition) { std::cerr << "FAIL: " << message << '\n'; std::abort(); }
}
void input(std::vector<float>& real, std::vector<float>& imaginary) {
    uint32_t state = 0x927ad63bu;
    auto random = [&] {
        state = state * 1664525u + 1013904223u;
        return static_cast<float>(static_cast<double>(state) / 2147483648.0 - 1.0);
    };
    for (size_t i = 0; i < real.size(); ++i) { real[i] = random(); imaginary[i] = random(); }
}
void checkDFT(size_t n, bool inverse) {
    hasio::PortableFFT fft(n);
    std::vector<float> real(n), imaginary(n); input(real, imaginary);
    const auto originalReal = real, originalImaginary = imaginary;
    if (inverse) fft.inverse(real.data(), imaginary.data());
    else fft.forward(real.data(), imaginary.data());
    // A direct double-precision DFT is independent of the FFT butterflies and
    // catches wrong sign, indexing, twiddles, or inverse normalization.
    for (size_t k = 0; k < n; ++k) {
        double expectedReal = 0, expectedImaginary = 0;
        for (size_t i = 0; i < n; ++i) {
            const double angle = (inverse ? tau : -tau) * k * i / n;
            expectedReal += originalReal[i] * std::cos(angle) - originalImaginary[i] * std::sin(angle);
            expectedImaginary += originalReal[i] * std::sin(angle) + originalImaginary[i] * std::cos(angle);
        }
        require(std::abs(real[k] - expectedReal) < 3.e-6 * std::sqrt(double(n)), "FFT real component differs from direct DFT");
        require(std::abs(imaginary[k] - expectedImaginary) < 3.e-6 * std::sqrt(double(n)), "FFT imaginary component differs from direct DFT");
    }
}
template<class Plan>
void checkRoundTrip(size_t n) {
    Plan fft(n);
    std::vector<float> real(n), imaginary(n); input(real, imaginary);
    const auto originalReal = real, originalImaginary = imaginary;
    const size_t allocationsBefore = allocationCount;
    fft.forward(real.data(), imaginary.data());
    fft.inverse(real.data(), imaginary.data());
    require(allocationCount == allocationsBefore, "FFT allocates while processing audio");
    for (size_t i = 0; i < n; ++i) {
        require(std::abs(real[i] / n - originalReal[i]) < 2.e-6, "Unnormalized FFT round trip changed the real input");
        require(std::abs(imaginary[i] / n - originalImaginary[i]) < 2.e-6, "Unnormalized FFT round trip changed the imaginary input");
    }
}
void checkTone(size_t n, size_t bin) {
    hasio::PortableFFT fft(n);
    std::vector<float> real(n), imaginary(n);
    for (size_t i = 0; i < n; ++i) {
        real[i] = static_cast<float>(std::cos(tau * bin * i / n));
        imaginary[i] = static_cast<float>(std::sin(tau * bin * i / n));
    }
    fft.forward(real.data(), imaginary.data());
    for (size_t k = 0; k < n; ++k) {
        require(std::abs(real[k] - (k == bin ? double(n) : 0.0)) < n * 2.e-7, "FFT tone amplitude or frequency bin changed");
        require(std::abs(imaginary[k]) < n * 2.e-7, "FFT tone phase changed");
    }
}
#if defined(__APPLE__) && !defined(HASIO_PORTABLE_DSP)
void checkAccelerate(size_t n, bool inverse) {
    hasio::PortableFFT portable(n); hasio::FFT accelerate(n);
    std::vector<float> real(n), imaginary(n); input(real, imaginary);
    auto referenceReal = real, referenceImaginary = imaginary;
    if (inverse) {
        portable.inverse(real.data(), imaginary.data());
        accelerate.inverse(referenceReal.data(), referenceImaginary.data());
    } else {
        portable.forward(real.data(), imaginary.data());
        accelerate.forward(referenceReal.data(), referenceImaginary.data());
    }
    double error = 0, referenceEnergy = 0;
    for (size_t i = 0; i < n; ++i) {
        const double dr = real[i] - referenceReal[i], di = imaginary[i] - referenceImaginary[i];
        error += dr * dr + di * di;
        referenceEnergy += double(referenceReal[i]) * referenceReal[i] + double(referenceImaginary[i]) * referenceImaginary[i];
        require(std::hypot(dr, di) < 1.e-5 * std::sqrt(double(n)), "FFT differs from Accelerate at a frequency bin");
    }
    const double relativeError = std::sqrt(error / referenceEnergy);
    require(relativeError < 5.e-7, "FFT aggregate error against Accelerate is excessive");
    std::cout << n << (inverse ? " inverse" : " forward") << " relative error against Accelerate: " << relativeError << '\n';
}
#endif
}

// Catch accidental scratch allocation in the audio-thread transform methods.
void* operator new(std::size_t bytes) {
    ++allocationCount;
    if (void* memory = std::malloc(bytes ? bytes : 1)) return memory;
    throw std::bad_alloc();
}
void* operator new[](std::size_t bytes) { return ::operator new(bytes); }
void operator delete(void* memory) noexcept { std::free(memory); }
void operator delete[](void* memory) noexcept { std::free(memory); }
void operator delete(void* memory, std::size_t) noexcept { std::free(memory); }
void operator delete[](void* memory, std::size_t) noexcept { std::free(memory); }

int main() {
    for (size_t invalid : {size_t(0), size_t(1), size_t(3), size_t(2047)}) {
        bool rejected = false;
        try { hasio::PortableFFT fft(invalid); } catch (const std::invalid_argument&) { rejected = true; }
        require(rejected, "FFT accepted an unsupported size");
    }
    for (size_t n : {size_t(2), size_t(4), size_t(8), size_t(64)}) {
        checkDFT(n, false); checkDFT(n, true);
    }
    for (size_t n : {size_t(2048), size_t(32768)}) {
        checkRoundTrip<hasio::PortableFFT>(n); checkRoundTrip<hasio::FFT>(n);
        for (size_t bin : {size_t(0), size_t(1), n / 2, n - 1}) checkTone(n, bin);
#if defined(__APPLE__) && !defined(HASIO_PORTABLE_DSP)
        checkAccelerate(n, false); checkAccelerate(n, true);
#endif
    }
    std::cout << "PASS: direct DFT, unnormalized inverse, phase, bin order, allocation-free FFT at audio and analysis sizes\n";
}
