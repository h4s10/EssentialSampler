#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd -P)"
target="${HASIO_DEV_DIR:-$HOME/Dev/EssentialSampler}"
if [[ "$project" == "$target" ]]; then
    echo "Project is already at $target"
    exit 0
fi
if [[ -e "$target" ]]; then
    echo "Destination already exists: $target"
    echo 'Nothing was overwritten. Choose a different destination or merge manually.'
    exit 1
fi
mkdir -p "$target"
/usr/bin/rsync -a --exclude='/build/' --exclude='.DS_Store' "$project/" "$target/"
echo "Project and releases copied to $target"
open "$target"
