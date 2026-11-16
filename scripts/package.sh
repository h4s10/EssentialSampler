#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=0.7.0
folder="releases/$version"
for extension in vst3 component app; do codesign --verify --strict "$folder/Essential Sampler.$extension"; done
cp README.md CHANGELOG.md THIRD_PARTY_NOTICES.md LICENSE "$folder/"
cp scripts/install-release.command "$folder/Install.command"
cp scripts/repair-au.command "$folder/Repair-AU.command"
chmod +x "$folder/Install.command" "$folder/Repair-AU.command"
mkdir -p "$folder/docs"
cp docs/{USAGE.md,DEVELOPMENT.md,VERIFICATION.md,preview.png,fx-preview.png} "$folder/docs/"
archive="releases/EssentialSampler-$version-macOS27-arm64-all.zip"
ditto -c -k --sequesterRsrc --keepParent "$folder" "$archive"
for format in VST3 AU; do
    stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    name="EssentialSampler-$version-macOS27-arm64-$format"
    mkdir -p "$stage/$name"
    extension=vst3; if [[ "$format" == AU ]]; then extension=component; fi
    ditto "$folder/Essential Sampler.$extension" "$stage/$name/Essential Sampler.$extension"
    cp "$folder/"{README.md,CHANGELOG.md,THIRD_PARTY_NOTICES.md,LICENSE,Install.command,Repair-AU.command} "$stage/$name/"
    ditto "$folder/docs" "$stage/$name/docs"
    ditto -c -k --sequesterRsrc --keepParent "$stage/$name" "releases/$name.zip"
    rm -rf "$stage"; trap - EXIT
done
(cd releases && shasum -a 256 EssentialSampler-"$version"-macOS27-arm64-{AU,VST3,all}.zip > SHA256SUMS.txt)
echo "Packaged AU, VST3 and combined archives under releases/."
