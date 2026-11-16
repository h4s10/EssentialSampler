#!/bin/bash
set -euo pipefail
folder="${HASIO_RELEASE_DIR:-$(cd "$(dirname "$0")" && pwd -P)}"
staging=''; probe_log=''
cleanup() {
    if [[ -n "$staging" ]]; then rm -rf "$staging"; fi
    if [[ -n "$probe_log" ]]; then rm -f "$probe_log"; fi
}
trap cleanup EXIT
verify_bundle() {
    local bundle="$1" expected_id="$2" actual_id
    codesign --verify --strict "$bundle"
    actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")"
    if [[ "$actual_id" != "$expected_id" ]]; then
        echo "Unexpected bundle identity: $actual_id. Nothing was changed."; exit 1
    fi
}
clear_bundle_quarantine() {
    local bundle="$1" attributes
    attributes="$(xattr -r "$bundle")"
    if [[ "$attributes" == *com.apple.quarantine* ]]; then
        echo 'Removing download quarantine from the verified Hasio Loop bundle.'
        xattr -dr com.apple.quarantine "$bundle"
    fi
}
validate_au() {
    local bundle="$1" registered=0 attempt validation_log
    probe_log="$(mktemp -t HasioLoop-au-list.XXXXXX)"
    is_registered() {
        arch -arm64 auval -a > "$probe_log" 2>&1 &&
            awk '$1 == "aumu" && $2 == "HsLp" && $3 == "Hasi" { found=1 } END { exit !found }' "$probe_log"
    }
    if is_registered; then registered=1
    else
        echo 'Refreshing the current user Audio Unit registry...'
        touch "$bundle" "$(dirname "$bundle")"
        # Do not stop the DAW, coreaudiod or another user's registrar.
        killall -u "$(id -un)" AudioComponentRegistrar >/dev/null 2>&1 || true
        for attempt in 1 2 3 4 5; do
            if is_registered; then registered=1; break; fi
            if [[ "$attempt" != 5 ]]; then sleep 1; fi
        done
    fi
    if [[ "$registered" == 0 ]]; then
        echo 'Hasio Loop is installed but not registered with Audio Unit yet.'
        echo 'Restart your Mac once, then open Logic or run: arch -arm64 auval -v aumu HsLp Hasi'
        echo 'This is a discovery failure; DSP validation has not started.'
        exit 3
    fi
    validation_log="$(mktemp -t HasioLoop-auval.XXXXXX)"
    if arch -arm64 auval -v aumu HsLp Hasi > "$validation_log" 2>&1; then
        cat "$validation_log"; rm -f "$validation_log"
    else
        cat "$validation_log"
        echo "Hasio Loop is registered, but AU validation failed. Log: $validation_log"
        echo 'Keep this log for troubleshooting; repeating a registry reset will not fix a DSP/API validation error.'
        exit 2
    fi
}
au_destination="${HASIO_AU_DIR:-$HOME/Library/Audio/Plug-Ins/Components}"
if [[ "${1:-}" == --repair-au ]]; then
    bundle="$au_destination/Hasio Loop.component"
    verify_bundle "$bundle" audio.hasio.loop.au
    clear_bundle_quarantine "$bundle"
    validate_au "$bundle"
    echo 'Open Logic: AU Instruments > hasio > Hasio Loop > Stereo.'
    exit 0
fi
if [[ $# -gt 0 && "$1" != vst3 && "$1" != component ]]; then
    echo 'Usage: Install.command [vst3|component|--repair-au]'; exit 1
fi
formats=''
for format in vst3 component; do
    if [[ -d "$folder/Hasio Loop.$format" && ( $# -eq 0 || "$1" == "$format" ) ]]; then
        expected_id=audio.hasio.loop.vst3
        if [[ "$format" == component ]]; then expected_id=audio.hasio.loop.au; fi
        verify_bundle "$folder/Hasio Loop.$format" "$expected_id"
        formats="$formats $format"
    fi
done
if [[ -z "$formats" ]]; then
    echo 'Keep Install.command beside Hasio Loop.vst3 and/or Hasio Loop.component.'; exit 1
fi
for format in $formats; do
    if [[ "$format" == vst3 ]]; then destination="${HASIO_VST3_DIR:-$HOME/Library/Audio/Plug-Ins/VST3}"
    else destination="$au_destination"; fi
    mkdir -p "$destination"
    staging="$(mktemp -d "$destination/.HasioLoop-install.XXXXXX")"
    ditto "$folder/Hasio Loop.$format" "$staging/Hasio Loop.$format"
    expected_id=audio.hasio.loop.vst3
    if [[ "$format" == component ]]; then expected_id=audio.hasio.loop.au; fi
    verify_bundle "$staging/Hasio Loop.$format" "$expected_id"
    clear_bundle_quarantine "$staging/Hasio Loop.$format"
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
if [[ " $formats " == *' component '* && "${HASIO_SKIP_AUVAL:-0}" != 1 ]]; then
    validate_au "$au_destination/Hasio Loop.component"
fi
echo 'Restart your DAW. Logic: Instrument > AU Instruments > hasio > Hasio Loop > Stereo.'
