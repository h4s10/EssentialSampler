#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
flags=(-std=c++17 -O1 -g -arch arm64 -mmacosx-version-min=27.0 -Isrc -Ithird_party)
clang++ "${flags[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer tests/engine_tests.cpp src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -framework Accelerate -o build/engine_tests
./build/engine_tests
clang++ "${flags[@]}" -fsanitize=address,undefined tests/effects_tests.cpp src/Effects.cpp -o build/effects_tests
./build/effects_tests
clang++ "${flags[@]}" -fsanitize=address,undefined tests/bandwidth_tests.cpp src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -framework Accelerate -o build/bandwidth_tests
./build/bandwidth_tests
clang++ "${flags[@]}" -fobjc-arc tests/host_tests.mm src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -framework Accelerate -framework Cocoa -o build/host_tests
./build/host_tests "releases/0.6.1/Hasio Loop.vst3/Contents/MacOS/HasioLoop"
python3 - <<'PY'
import math, struct, wave
with wave.open('build/test.wav', 'wb') as f:
    f.setnchannels(2); f.setsampwidth(2); f.setframerate(48000)
    f.writeframes(b''.join(struct.pack('<hh', int(16384 * math.sin(i * math.tau * 220 / 48000)), int(16384 * math.sin(i * math.tau * 330 / 48000))) for i in range(48000)))
PY
afconvert -f AIFF -d BEI16 build/test.wav build/test.aiff
if command -v flac >/dev/null; then
    flac --silent --force -o build/test.flac build/test.wav
else
    echo 'FLAC encoder unavailable; using committed test fixture.'
    cp tests/fixtures/tone.flac build/test.flac
fi
clang++ "${flags[@]}" -fobjc-arc tests/ui_smoke.mm build/obj/{Engine,Effects,PitchShifter,Editor,AudioFile}.o third_party/flac/lib/libFLAC.a third_party/ogg/lib/libogg.a -framework Cocoa -framework AudioToolbox -framework UniformTypeIdentifiers -framework Accelerate -o build/ui_smoke
./build/ui_smoke build/test.wav build/test.aiff build/test.flac
clang++ "${flags[@]}" -fobjc-arc tests/keyboard_tests.mm build/obj/{Engine,Effects,PitchShifter,Editor,AudioFile}.o third_party/flac/lib/libFLAC.a third_party/ogg/lib/libogg.a -framework Cocoa -framework AudioToolbox -framework UniformTypeIdentifiers -framework Accelerate -o build/keyboard_tests
./build/keyboard_tests
clang++ "${flags[@]}" -fobjc-arc tests/au_host_tests.mm src/Engine.cpp src/Effects.cpp src/PitchShifter.cpp -framework Cocoa -framework AudioToolbox -framework Accelerate -o build/au_host_tests
./build/au_host_tests "$PWD/releases/0.6.1/Hasio Loop.component" --direct
# Full OS component registration/validation is a separate check on an unrestricted Mac:
# ./build/au_host_tests "$PWD/releases/0.6.1/Hasio Loop.component" validate
codesign --verify --strict "releases/0.6.1/Hasio Loop.component"
codesign --verify --strict "releases/0.6.1/Hasio Loop.vst3"
codesign --verify --strict "releases/0.6.1/Hasio Loop.app"
python3 tests/installer_tests.py
echo 'All checks passed.'
