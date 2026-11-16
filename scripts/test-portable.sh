#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/portable
flags=(-std=c++17 -O1 -g -DHASIO_PORTABLE_DSP=1 -fsanitize=address,undefined -fno-omit-frame-pointer -Isrc -Ithird_party)
clang++ "${flags[@]}" tests/fft_tests.cpp -o build/portable/fft_tests
./build/portable/fft_tests
for suite in engine bandwidth; do
    clang++ "${flags[@]}" "tests/${suite}_tests.cpp" src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -o "build/portable/${suite}_tests"
    "./build/portable/${suite}_tests"
done
clang++ "${flags[@]}" tests/audio_file_tests.cpp src/AudioFileWindows.cpp src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -o build/portable/audio_file_tests
./build/portable/audio_file_tests
echo 'All portable checks passed (no Apple DSP or audio frameworks linked).'
