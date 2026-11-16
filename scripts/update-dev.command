#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd -P)"
target="${HASIO_DEV_DIR:-$HOME/Dev/HasioLoop}"
source_bundle="$project/releases/0.6.1/Hasio Loop.vst3"
if [[ ! -f "$source_bundle/Contents/MacOS/HasioLoop" ]]; then
    echo 'Release 0.6.1 is missing. Run bash scripts/build.sh first.'; exit 1
fi
codesign --verify --strict "$source_bundle"
mkdir -p "$target"
target="$(cd "$target" && pwd -P)"
if [[ "$target" != "$project" ]]; then
    case "$project/" in "$target/"*) echo 'Source cannot be inside the destination.'; exit 1;; esac
    case "$target/" in "$project/"*) echo 'Destination cannot be inside the source.'; exit 1;; esac
    backup="$(dirname "$target")/HasioLoop-backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$backup"
    /usr/bin/rsync -a --exclude='/build/' --exclude='.DS_Store' "$target/" "$backup/"
    echo "Previous project kept at $backup"
    /usr/bin/rsync -a --exclude='/build/' --exclude='/.git/' --exclude='.DS_Store' "$project/" "$target/"
    echo "Updated project: $target"
fi
HASIO_RELEASE_DIR="$target/releases/0.6.1" bash "$target/scripts/install-release.command"
