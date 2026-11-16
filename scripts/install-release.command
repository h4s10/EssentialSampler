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
        echo 'Removing download quarantine from the verified Essential Sampler bundle.'
        xattr -dr com.apple.quarantine "$bundle"
    fi
}
validate_au() {
    local bundle="$1" force_refresh="${2:-0}" registered=0 attempt validation_log
    probe_log="$(mktemp -t EssentialSampler-au-list.XXXXXX)"
    is_registered() {
        arch -arm64 auval -a > "$probe_log" 2>&1 &&
            awk '$1 == "aumu" && $2 == "HsLp" && $3 == "Hasi" { found=1 } END { exit !found }' "$probe_log"
    }
    if is_registered && [[ "$force_refresh" == 0 ]]; then registered=1
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
        echo 'Essential Sampler is installed but not registered with Audio Unit yet.'
        echo 'Restart your Mac once, then open Logic or run: arch -arm64 auval -v aumu HsLp Hasi'
        echo 'This is a discovery failure; DSP validation has not started.'
        exit 3
    fi
    validation_log="$(mktemp -t EssentialSampler-auval.XXXXXX)"
    if arch -arm64 auval -v aumu HsLp Hasi > "$validation_log" 2>&1; then
        cat "$validation_log"; rm -f "$validation_log"
    else
        cat "$validation_log"
        echo "Essential Sampler is registered, but AU validation failed. Log: $validation_log"
        echo 'Keep this log for troubleshooting; repeating a registry reset will not fix a DSP/API validation error.'
        exit 2
    fi
}
au_destination="${HASIO_AU_DIR:-$HOME/Library/Audio/Plug-Ins/Components}"
if [[ "${1:-}" == --repair-au ]]; then
    bundle="$au_destination/Essential Sampler.component"
    display_name="Essential Sampler"
    # Repair remains usable for installations made before the display-name change.
    if [[ ! -e "$bundle" && -d "$au_destination/Hasio Loop.component" ]]; then
        bundle="$au_destination/Hasio Loop.component"
        display_name="Hasio Loop"
        echo "Legacy version detected. Run Install.command to upgrade its name to Essential Sampler."
    fi
    verify_bundle "$bundle" audio.hasio.loop.au
    clear_bundle_quarantine "$bundle"
    validate_au "$bundle"
    echo "Open Logic: AU Instruments > hasio > $display_name > Stereo."
    exit 0
fi
if [[ $# -gt 0 && "$1" != vst3 && "$1" != component ]]; then
    echo 'Usage: Install.command [vst3|component|--repair-au]'; exit 1
fi
formats=''
for format in vst3 component; do
    if [[ -d "$folder/Essential Sampler.$format" && ( $# -eq 0 || "$1" == "$format" ) ]]; then
        expected_id=audio.hasio.loop.vst3
        if [[ "$format" == component ]]; then expected_id=audio.hasio.loop.au; fi
        verify_bundle "$folder/Essential Sampler.$format" "$expected_id"
        formats="$formats $format"
    fi
done
if [[ -z "$formats" ]]; then
    echo 'Keep Install.command beside Essential Sampler.vst3 and/or Essential Sampler.component.'; exit 1
fi
au_renamed=0
for format in $formats; do
    if [[ "$format" == vst3 ]]; then destination="${HASIO_VST3_DIR:-$HOME/Library/Audio/Plug-Ins/VST3}"
    else destination="$au_destination"; fi
    mkdir -p "$destination"
    staging="$(mktemp -d "$destination/.EssentialSampler-install.XXXXXX")"
    ditto "$folder/Essential Sampler.$format" "$staging/Essential Sampler.$format"
    expected_id=audio.hasio.loop.vst3
    if [[ "$format" == component ]]; then expected_id=audio.hasio.loop.au; fi
    verify_bundle "$staging/Essential Sampler.$format" "$expected_id"
    clear_bundle_quarantine "$staging/Essential Sampler.$format"
    # Both names have the same plugin identity; leaving the old one installed
    # can make a host choose the stale bundle. Preserve it as an unscanned backup.
    for previous in "Essential Sampler" "Hasio Loop"; do
        if [[ -e "$destination/$previous.$format" ]]; then
            verify_bundle "$destination/$previous.$format" "$expected_id"
        fi
    done
    originals=(); backups=(); saved=0
    restore_previous() {
        local i
        for ((i=saved-1; i>=0; --i)); do
            mv "${backups[$i]}" "${originals[$i]}"
        done
    }
    for previous in "Essential Sampler" "Hasio Loop"; do
        original="$destination/$previous.$format"
        if [[ -e "$original" ]]; then
            backup="$original.backup-$(date +%Y%m%d-%H%M%S)-$$"
            if ! mv "$original" "$backup"; then restore_previous; exit 1; fi
            originals[$saved]="$original"; backups[$saved]="$backup"; saved=$((saved+1))
            if [[ "$format" == component && "$previous" == 'Hasio Loop' ]]; then au_renamed=1; fi
            echo "Previous version kept at $backup"
        fi
    done
    if ! mv "$staging/Essential Sampler.$format" "$destination/Essential Sampler.$format"; then
        restore_previous
        exit 1
    fi
    rmdir "$staging"; staging=''
    echo "Installed: $destination/Essential Sampler.$format"
done
if [[ " $formats " == *' component '* && "${HASIO_SKIP_AUVAL:-0}" != 1 ]]; then
    validate_au "$au_destination/Essential Sampler.component" "$au_renamed"
fi
echo 'Restart your DAW. Logic: Instrument > AU Instruments > hasio > Essential Sampler > Stereo.'
