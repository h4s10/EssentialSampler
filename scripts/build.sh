#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/obj releases/0.6.0
flags=(-std=c++17 -O2 -g -arch arm64 -mmacosx-version-min=27.0 -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -Isrc -Ithird_party -Ithird_party/flac/include)
frameworks=(-framework Cocoa -framework AudioToolbox -framework CoreAudio -framework UniformTypeIdentifiers -framework Accelerate)
libraries=(third_party/flac/lib/libFLAC.a third_party/ogg/lib/libogg.a)
for source in Effects.cpp PitchShifter.cpp Engine.cpp AudioFile.mm Editor.mm Plugin.mm Standalone.mm AudioUnit.mm; do
    echo "Compiling $source"
    if [[ "$source" == *.mm ]]; then
        extra=(-DHASIO_BUILD=1); if [[ "$source" == AudioUnit.mm ]]; then extra=(-DHLView=HLAUView); fi
        clang++ "${flags[@]}" "${extra[@]}" -fobjc-arc -c "src/$source" -o "build/obj/${source%.*}.o"
    else
        clang++ "${flags[@]}" -c "src/$source" -o "build/obj/${source%.*}.o"
    fi
done
clang++ "${flags[@]}" -fobjc-arc -DHLView=HLAUView -c src/Editor.mm -o build/obj/EditorAU.o
component="releases/0.6.0/Hasio Loop.component"
mkdir -p "$component/Contents/MacOS"
clang++ -bundle -arch arm64 -mmacosx-version-min=27.0 build/obj/{Engine,Effects,PitchShifter,AudioFile,EditorAU,AudioUnit}.o "${libraries[@]}" "${frameworks[@]}" -o "$component/Contents/MacOS/HasioLoop"
plugin="releases/0.6.0/Hasio Loop.vst3"
app="releases/0.6.0/Hasio Loop.app"
mkdir -p "$plugin/Contents/MacOS" "$plugin/Contents/Resources" "$app/Contents/MacOS"
clang++ -bundle -arch arm64 -mmacosx-version-min=27.0 build/obj/{Engine,Effects,PitchShifter,AudioFile,Editor,Plugin}.o "${libraries[@]}" "${frameworks[@]}" -o "$plugin/Contents/MacOS/HasioLoop"
clang++ -arch arm64 -mmacosx-version-min=27.0 build/obj/{Engine,Effects,PitchShifter,AudioFile,Editor,Standalone}.o "${libraries[@]}" "${frameworks[@]}" -o "$app/Contents/MacOS/HasioLoop"
python3 scripts/bundle_info.py
for bundle in "$plugin" "$app" "$component"; do
    mkdir -p "$bundle/Contents/Resources/Licenses"
    cp LICENSE "$bundle/Contents/Resources/Licenses/EssentialSampler-MIT.txt"
    cp third_party/pluginterfaces/LICENSE.txt "$bundle/Contents/Resources/Licenses/VST3.txt"
    cp third_party/flac/LICENSE "$bundle/Contents/Resources/Licenses/FLAC.txt"
    cp third_party/ogg/LICENSE "$bundle/Contents/Resources/Licenses/Ogg.txt"
done
codesign --force --sign - --timestamp=none "$plugin"
codesign --force --sign - --timestamp=none "$app"
codesign --force --sign - --timestamp=none "$component"
echo "Built: $component"
echo "Built: $plugin"
echo "Built: $app"
