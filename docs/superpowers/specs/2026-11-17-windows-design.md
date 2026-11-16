# Essential Sampler 0.7.0: Windows and stable release

Publish macOS arm64 AU/VST3/standalone and Windows x64 VST3/standalone as one stable release. Preserve the existing plugin identities, parameter IDs, embedded sample state and DSP behavior. Keep native editors and the existing dark waveform layout.

Windows uses a Win32 child editor, a WinMM standalone output, portable radix-2 FFT and WAV/AIFF/FLAC decoding. macOS retains Cocoa, AudioToolbox and Accelerate. Build Windows with CMake/MSVC and a static runtime, then execute DSP, decoder, plugin-host and editor lifecycle tests on a native GitHub Actions Windows runner. No runtime dependency download is required.

The Windows VST3 bundle installs to Common Files/VST3 with explicit UAC elevation by the installer; manual copying remains supported. Packages include English documentation and all dependency licenses. Release evidence must distinguish automated host tests from unperformed tests in commercial DAWs. Existing public history is retained; current documentation and release descriptions use only Essential Sampler branding.
