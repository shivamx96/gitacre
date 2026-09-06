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
release_label=${GITACRE_RELEASE_LABEL:-$version}
appcast_url=${GITACRE_APPCAST_URL:-}
public_key=${GITACRE_SPARKLE_PUBLIC_KEY:-}

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

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$source_plist" "$app_bundle/Contents/Info.plist"
cp "$binary_directory/Gitacre" "$app_bundle/Contents/MacOS/Gitacre"
swift "$repository/scripts/generate-icon.swift" "$app_bundle/Contents/Resources/AppIcon.icns"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :GitacreReleaseLabel $release_label" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $appcast_url" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $public_key" "$app_bundle/Contents/Info.plist"

# Sparkle ships as a binary XCFramework. SwiftPM leaves it beside the executable, but a
# bundle needs it in Contents/Frameworks, and the binary needs an rpath that points there.
sparkle_framework=$(
    find "$repository/.build/artifacts" \
        -type d \
        -path "*macos-arm64_x86_64/Sparkle.framework" \
        -print -quit
)

if [[ -z "$sparkle_framework" ]]; then
    echo "Sparkle.framework was not found. Run 'swift package resolve' first." >&2
    exit 1
fi

rm -rf -- "$app_bundle/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/Gitacre" 2>/dev/null || true

# Nested code must be signed before the code that contains it, innermost first.
# --deep is not a substitute: it cannot apply the hardened runtime per nested bundle.
declare -a nested_code=(
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
    "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "Contents/Frameworks/Sparkle.framework/Versions/B"
)

sign() {
    local target=$1
    if [[ "$signing_identity" == "-" ]]; then
        codesign --force --sign - "$target" >/dev/null
    else
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$signing_identity" \
            "$target" >/dev/null
    fi
}

for relative_path in "${nested_code[@]}"; do
    if [[ -e "$app_bundle/$relative_path" ]]; then
        sign "$app_bundle/$relative_path"
    fi
done

sign "$app_bundle"

codesign --verify --deep --strict --verbose=2 "$app_bundle"

echo "$app_bundle"
