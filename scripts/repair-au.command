#!/bin/bash
set -euo pipefail
folder="$(cd "$(dirname "$0")" && pwd -P)"
if [[ -f "$folder/Install.command" ]]; then
    exec bash "$folder/Install.command" --repair-au
fi
exec bash "$folder/install-release.command" --repair-au
