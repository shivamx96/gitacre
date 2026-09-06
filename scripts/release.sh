#!/usr/bin/env bash

set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
release_label=${1:-}
build_number=${2:-1}

if [[ ! "$release_label" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z][0-9A-Za-z.-]*$ ]]; then
    echo "Usage: scripts/release.sh <version-label> [build-number]" >&2
    echo "Example: scripts/release.sh 1.0.0-beta 1" >&2
    exit 2
fi

if [[ ! "$build_number" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    echo "Build number must contain one or more period-separated integers." >&2
    exit 2
fi

marketing_version=${release_label%%-*}
notary_profile=${GITACRE_NOTARY_PROFILE:-gitacre-notary}
appcast_url=${GITACRE_APPCAST_URL:-https://gitacre.app/appcast.xml}
appcast_path=${GITACRE_APPCAST_PATH:-$repository/website/appcast.xml}
public_key=${GITACRE_SPARKLE_PUBLIC_KEY:-}
skip_appcast=${GITACRE_SKIP_APPCAST:-0}
download_url_prefix=${GITACRE_DOWNLOAD_URL_PREFIX:-https://github.com/shivamx96/gitacre/releases/download/v$release_label}
release_notes_link=${GITACRE_RELEASE_NOTES_LINK:-https://github.com/shivamx96/gitacre/releases/tag/v$release_label}
skip_notarization=${GITACRE_SKIP_NOTARIZATION:-0}
allow_adhoc=${GITACRE_ALLOW_ADHOC:-0}
signing_identity=${GITACRE_SIGNING_IDENTITY:-}

if [[ -z "$signing_identity" ]]; then
    signing_identity=$(
        security find-identity -v -p codesigning \
            | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
            | head -n 1
    )
fi

if [[ -z "$signing_identity" ]]; then
    if [[ "$allow_adhoc" == "1" ]]; then
        signing_identity="-"
    else
        echo "No Developer ID Application identity was found." >&2
        echo "Install one or set GITACRE_SIGNING_IDENTITY explicitly." >&2
        echo "For a local-only candidate, set GITACRE_ALLOW_ADHOC=1 and GITACRE_SKIP_NOTARIZATION=1." >&2
        exit 1
    fi
fi

if [[ "$signing_identity" == "-" && "$skip_notarization" != "1" ]]; then
    echo "Ad hoc builds cannot be notarized. Set GITACRE_SKIP_NOTARIZATION=1." >&2
    exit 1
fi

artifact_suffix=""
if [[ "$signing_identity" == "-" ]]; then
    artifact_suffix="-local"
fi

output_directory="$repository/dist"
app_bundle="$repository/build/gitacre.app"
dmg_path="$output_directory/gitacre-$release_label$artifact_suffix.dmg"
checksum_path="$dmg_path.sha256"
work_directory=$(mktemp -d /tmp/gitacre-release.XXXXXX)

cleanup() {
    if [[ "$work_directory" == /tmp/gitacre-release.* ]]; then
        rm -rf -- "$work_directory"
    fi
}
trap cleanup EXIT

mkdir -p "$output_directory"
rm -f -- "$dmg_path" "$checksum_path"

if [[ -z "$public_key" && "$skip_appcast" != "1" ]]; then
    echo "GITACRE_SPARKLE_PUBLIC_KEY is not set, so the build could not verify updates." >&2
    echo "Create a key once with .build/artifacts/sparkle/Sparkle/bin/generate_keys," >&2
    echo "then export its public half. For a build without updates, set GITACRE_SKIP_APPCAST=1." >&2
    exit 1
fi

GITACRE_VERSION="$marketing_version" \
GITACRE_BUILD_NUMBER="$build_number" \
GITACRE_RELEASE_LABEL="$release_label" \
GITACRE_APPCAST_URL="$appcast_url" \
GITACRE_SPARKLE_PUBLIC_KEY="$public_key" \
GITACRE_ARCHS="arm64 x86_64" \
GITACRE_SIGNING_IDENTITY="$signing_identity" \
    "$repository/scripts/build-app.sh" release

architectures=$(lipo -archs "$app_bundle/Contents/MacOS/Gitacre")
for required_architecture in arm64 x86_64; do
    if [[ " $architectures " != *" $required_architecture "* ]]; then
        echo "Release binary is missing $required_architecture." >&2
        exit 1
    fi
done

if [[ "$skip_notarization" != "1" ]]; then
    archive_path="$work_directory/gitacre-$release_label.zip"
    ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$archive_path"
    xcrun notarytool submit "$archive_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app_bundle"
    xcrun stapler validate "$app_bundle"
fi

staging_directory="$work_directory/disk-image"
mkdir -p "$staging_directory"
ditto "$app_bundle" "$staging_directory/gitacre.app"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
    -volname "gitacre $release_label" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$dmg_path"

if [[ "$skip_notarization" != "1" ]]; then
    codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg_path"
fi

hdiutil verify "$dmg_path"
(
    cd "$output_directory"
    shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$checksum_path")"
)

if [[ "$skip_appcast" != "1" ]]; then
    sign_update=$(
        find "$repository/.build/artifacts" -type f -path "*Sparkle/bin/sign_update" -print -quit
    )

    if [[ -z "$sign_update" ]]; then
        echo "sign_update was not found. Run 'swift package resolve' first." >&2
        exit 1
    fi

    # sign_update prints the enclosure attributes, for example:
    #   sparkle:edSignature="..." length="12345"
    signature_attributes=$("$sign_update" "$dmg_path")
    signature=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$signature_attributes")
    length=$(sed -n 's/.*length="\([^"]*\)".*/\1/p' <<< "$signature_attributes")

    if [[ -z "$signature" || -z "$length" ]]; then
        echo "Could not read a signature from sign_update: $signature_attributes" >&2
        exit 1
    fi

    python3 "$repository/scripts/update-appcast.py" \
        --appcast "$appcast_path" \
        --version "$build_number" \
        --short-version "$release_label" \
        --url "$download_url_prefix/$(basename "$dmg_path")" \
        --length "$length" \
        --signature "$signature" \
        --minimum-system-version "$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app_bundle/Contents/Info.plist")" \
        --release-notes-link "$release_notes_link"
fi

printf '\nRelease candidate created:\n%s\n%s\n' "$dmg_path" "$checksum_path"

if [[ "$skip_appcast" != "1" ]]; then
    printf '\nAppcast updated:\n%s\n\nPublish it by uploading the disk image to the v%s release and deploying the website.\n' \
        "$appcast_path" "$release_label"
fi
