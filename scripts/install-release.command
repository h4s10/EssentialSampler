#!/bin/bash
set -euo pipefail
folder="${HASIO_RELEASE_DIR:-$(cd "$(dirname "$0")" && pwd -P)}"
formats=()
for format in vst3 component; do
    if [[ -d "$folder/Hasio Loop.$format" && ( $# -eq 0 || "$1" == "$format" ) ]]; then
        codesign --verify --strict "$folder/Hasio Loop.$format"
        formats+=("$format")
    fi
done
if [[ ${#formats[@]} -eq 0 ]]; then
    echo 'Keep Install.command beside Hasio Loop.vst3 and/or Hasio Loop.component.'; exit 1
fi
staging=''
trap 'if [[ -n "$staging" ]]; then rm -rf "$staging"; fi' EXIT
for format in "${formats[@]}"; do
    if [[ "$format" == vst3 ]]; then destination="${HASIO_VST3_DIR:-$HOME/Library/Audio/Plug-Ins/VST3}"
    else destination="${HASIO_AU_DIR:-$HOME/Library/Audio/Plug-Ins/Components}"; fi
    mkdir -p "$destination"
    staging="$(mktemp -d "$destination/.HasioLoop-install.XXXXXX")"
    ditto "$folder/Hasio Loop.$format" "$staging/Hasio Loop.$format"
    codesign --verify --strict "$staging/Hasio Loop.$format"
    backup=''
    if [[ -e "$destination/Hasio Loop.$format" ]]; then
        backup="$destination/Hasio Loop.$format.backup-$(date +%Y%m%d-%H%M%S)-$$"
        mv "$destination/Hasio Loop.$format" "$backup"
        echo "Previous version kept at $backup"
    fi
    if ! mv "$staging/Hasio Loop.$format" "$destination/Hasio Loop.$format"; then
        if [[ -n "$backup" ]]; then mv "$backup" "$destination/Hasio Loop.$format"; fi
        exit 1
    fi
    rmdir "$staging"; staging=''
    echo "Installed: $destination/Hasio Loop.$format"
done
if [[ " ${formats[*]} " == *' component '* && "${HASIO_SKIP_AUVAL:-0}" != 1 ]]; then
    if ! /usr/bin/auval -v aumu HsLp Hasi; then
        echo 'Files installed, but AU validation did not pass. Restart Logic and use Plug-in Manager > Reset & Rescan Selection.'
        exit 2
    fi
fi
echo 'Restart your DAW. Logic: Instrument > AU Instruments > hasio > Hasio Loop > Stereo.'
