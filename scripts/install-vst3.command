#!/bin/bash
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd -P)"
HASIO_RELEASE_DIR="$project/releases/0.6.1" bash "$project/scripts/install-release.command" vst3
