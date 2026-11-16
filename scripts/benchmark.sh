#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=27.0 -Isrc tests/pitch_benchmark.cpp src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -framework Accelerate -o build/pitch_benchmark
./build/pitch_benchmark
