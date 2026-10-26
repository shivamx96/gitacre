#!/usr/bin/env bash

# Shared, side-effect-free validation used before release.sh touches signing or artifacts.
set -euo pipefail

release_label=${1:-}
build_number=${2:-1}

if [[ ! "$release_label" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]; then
    echo "Usage: scripts/release.sh <version-label> [build-number]" >&2
    echo "Examples: scripts/release.sh 1.0.0 7 or scripts/release.sh 1.0.0-beta.6 6" >&2
    exit 2
fi

if [[ ! "$build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "Build number must contain one or more period-separated integers." >&2
    exit 2
fi
