# Releasing gitacre

gitacre is distributed outside the Mac App Store as a universal, Developer ID-signed, notarized disk image.

The prerelease label belongs in the Git tag and artifact name. Apple bundle metadata remains numeric: `1.0.0-beta` is packaged with `CFBundleShortVersionString` set to `1.0.0` and an independently increasing `CFBundleVersion`.

## One-time signing setup

1. In Xcode, open **Settings → Accounts → Manage Certificates** and create or install a **Developer ID Application** certificate for team `RP9BF8YGPZ`.
2. Store notarization credentials in the login keychain. This command prompts securely for the app-specific password:

   ```sh
   xcrun notarytool store-credentials gitacre-notary \
     --apple-id "YOUR_APPLE_ID" \
     --team-id "RP9BF8YGPZ"
   ```

Never place the Apple ID password, API private key, or signing certificate in the repository.

## Build the release candidate

From a clean checkout on `main`:

```sh
GITACRE_SIGNING_IDENTITY="Developer ID Application: Shivam Shekhar (RP9BF8YGPZ)" \
  scripts/release.sh 1.0.0-beta 1
```

The script builds a universal `arm64` and `x86_64` app, enables the hardened runtime, submits the app and disk image to Apple's notary service, staples both tickets, runs Gatekeeper and disk-image verification, and writes a SHA-256 checksum under `dist/`.

For pipeline testing only, an explicitly marked local artifact can be created without Developer ID credentials:

```sh
GITACRE_ALLOW_ADHOC=1 GITACRE_SKIP_NOTARIZATION=1 \
  scripts/release.sh 1.0.0-beta 1
```

The resulting `-local.dmg` is not suitable for public distribution.

## Publish

Publication is intentionally manual. Confirm the repository is ready to become public, review `release-notes/1.0.0-beta.md`, and obtain approval before pushing the release commit or tag.

After approval:

```sh
git tag -a v1.0.0-beta -m "gitacre 1.0.0-beta"
git push origin main v1.0.0-beta
gh release create v1.0.0-beta \
  dist/gitacre-1.0.0-beta.dmg \
  dist/gitacre-1.0.0-beta.dmg.sha256 \
  --prerelease \
  --title "gitacre 1.0.0-beta" \
  --notes-file release-notes/1.0.0-beta.md
```

Once the release and public repository are available, set `releasesEnabled` to `true` in `website/script.js`, verify the download link, and deploy the website container again.
