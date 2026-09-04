#!/usr/bin/env bash

set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
configuration=${1:-release}

case "$configuration" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 2
        ;;
esac

swift build --package-path "$repository" --configuration "$configuration"
binary_directory=$(swift build --package-path "$repository" --configuration "$configuration" --show-bin-path)

output_root="$repository/build"
app_bundle="$output_root/Gitacre.app"

if [ -e "$app_bundle" ]; then
    rm -rf -- "$app_bundle"
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$repository/Support/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$binary_directory/Gitacre" "$app_bundle/Contents/MacOS/Gitacre"
swift "$repository/scripts/generate-icon.swift" "$app_bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app_bundle" >/dev/null

echo "$app_bundle"
