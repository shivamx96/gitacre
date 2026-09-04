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

source_plist="$repository/Support/Info.plist"
version=${GITACRE_VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$source_plist")}
build_number=${GITACRE_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$source_plist")}
signing_identity=${GITACRE_SIGNING_IDENTITY:--}

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "GITACRE_VERSION must contain three period-separated integers (for example, 1.0.0)." >&2
    exit 2
fi

if [[ ! "$build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "GITACRE_BUILD_NUMBER must contain one or more period-separated integers." >&2
    exit 2
fi

declare -a architectures
if [[ -n "${GITACRE_ARCHS:-}" ]]; then
    read -r -a architectures <<< "$GITACRE_ARCHS"
elif [[ "$configuration" == "release" ]]; then
    architectures=(arm64 x86_64)
else
    architectures=("$(uname -m)")
fi

declare -a swift_arguments=(
    build
    --package-path "$repository"
    --configuration "$configuration"
)

for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *)
            echo "Unsupported architecture: $architecture" >&2
            exit 2
            ;;
    esac
    swift_arguments+=(--arch "$architecture")
done

swift "${swift_arguments[@]}"
binary_directory=$(swift "${swift_arguments[@]}" --show-bin-path)

output_root="$repository/build"
app_bundle="$output_root/gitacre.app"
legacy_app_bundle="$output_root/Gitacre.app"

if [ -e "$app_bundle" ]; then
    rm -rf -- "$app_bundle"
fi
if [ -e "$legacy_app_bundle" ]; then
    rm -rf -- "$legacy_app_bundle"
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$source_plist" "$app_bundle/Contents/Info.plist"
cp "$binary_directory/Gitacre" "$app_bundle/Contents/MacOS/Gitacre"
swift "$repository/scripts/generate-icon.swift" "$app_bundle/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"

if [[ "$signing_identity" == "-" ]]; then
    codesign --force --sign - "$app_bundle" >/dev/null
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        "$app_bundle" >/dev/null
fi

codesign --verify --deep --strict --verbose=2 "$app_bundle"

echo "$app_bundle"
