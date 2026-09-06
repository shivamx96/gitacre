# Releasing gitacre

gitacre is distributed outside the Mac App Store as a universal, Developer ID-signed, notarized disk image.

The prerelease label belongs in the Git tag and artifact name. Apple bundle metadata remains numeric: `1.0.0-beta` is packaged with `CFBundleShortVersionString` set to `1.0.0` and an independently increasing `CFBundleVersion`. The full label is also written to `GitacreReleaseLabel`, so the app can tell `1.0.0-beta` from `1.0.0` even though the two share a short version string.

**`CFBundleVersion` must increase with every release.** It is the number Sparkle compares to decide whether an update exists; the marketing version plays no part. `scripts/release.sh` refuses to publish a build number that is not greater than the newest already in the appcast.

## One-time signing setup

1. In Xcode, open **Settings → Accounts → Manage Certificates** and create or install a **Developer ID Application** certificate for team `RP9BF8YGPZ`.
2. Store notarization credentials in the login keychain. This command prompts securely for the app-specific password:

   ```sh
   xcrun notarytool store-credentials gitacre-notary \
     --apple-id "YOUR_APPLE_ID" \
     --team-id "RP9BF8YGPZ"
   ```

3. Generate the EdDSA key Sparkle uses to sign updates. This is separate from the Developer ID certificate and only needs doing once, ever:

   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   The private key is stored in the login keychain. Print the public half with `generate_keys -p` and export it for builds:

   ```sh
   export GITACRE_SPARKLE_PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)"
   ```

   The public key is baked into the app as `SUPublicEDKey`. An app can only accept updates signed by the matching private key, so **losing the private key means shipping users can never be updated again** — back it up with `generate_keys -x`.

Never place the Apple ID password, API private key, signing certificate, or the Sparkle private key in the repository.

## Build the release candidate

From a clean checkout on `main`:

```sh
GITACRE_SIGNING_IDENTITY="Developer ID Application: Shivam Shekhar (RP9BF8YGPZ)" \
GITACRE_SPARKLE_PUBLIC_KEY="$(.build/artifacts/sparkle/Sparkle/bin/generate_keys -p)" \
  scripts/release.sh 1.1.0-beta 2
```

The script builds a universal `arm64` and `x86_64` app, embeds and signs `Sparkle.framework`, enables the hardened runtime, submits the app and disk image to Apple's notary service, staples both tickets, runs Gatekeeper and disk-image verification, and writes a SHA-256 checksum under `dist/`.

It then signs the disk image with the Sparkle key and writes the release into `website/appcast.xml`.

The feed defaults to the copy of that file served from `main`:

```
https://raw.githubusercontent.com/shivamx96/gitacre/main/website/appcast.xml
```

**Merging the release commit into `main` is what publishes the update.** The file also ships with the website container, so moving the feed to a domain later is a matter of changing `GITACRE_APPCAST_URL` for the next build. It is baked into each app as `SUFeedURL` and cannot be repointed afterwards, so existing installs keep polling whichever URL they were built with — never retire an old feed URL, redirect it.

| Variable | Purpose |
| --- | --- |
| `GITACRE_SPARKLE_PUBLIC_KEY` | Public half of the update signing key, baked in as `SUPublicEDKey` |
| `GITACRE_APPCAST_URL` | Feed the app polls, baked in as `SUFeedURL` |
| `GITACRE_APPCAST_PATH` | Where to write the feed (default `website/appcast.xml`) |
| `GITACRE_DOWNLOAD_URL_PREFIX` | Where the disk image will be published |
| `GITACRE_SKIP_APPCAST` | Set to `1` to build without touching the feed |

For pipeline testing only, an explicitly marked local artifact can be created without Developer ID credentials:

```sh
GITACRE_ALLOW_ADHOC=1 GITACRE_SKIP_NOTARIZATION=1 GITACRE_SKIP_APPCAST=1 \
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

Once the release and public repository are available, verify the download link and deploy the website container again. The site reads the newest published release from the GitHub API, so it needs no edit per release. It deliberately uses the release *list* rather than `/releases/latest`, which excludes prereleases and answers 404 while every release is a prerelease.

## Publish the update feed

Landing `website/appcast.xml` on `main` is what actually ships the update. Nothing reaches existing installs until it is there.

```sh
git add website/appcast.xml release-notes/
git commit -m "Publish 1.1.0-beta to the update feed"
git push origin main
curl -sSf https://raw.githubusercontent.com/shivamx96/gitacre/main/website/appcast.xml | head
```

Check that the newest `<item>` carries the right `sparkle:version`, that its `enclosure url` resolves, and that `sparkle:edSignature` is present. An entry whose signature does not match the disk image is rejected by every client, silently, so verify before announcing:

```sh
.build/artifacts/sparkle/Sparkle/bin/sign_update --verify \
  dist/gitacre-1.1.0-beta.dmg "<signature from the appcast>"
```

## Bootstrapping note

1.0.0-beta shipped without an updater, so it cannot install 1.1.0-beta over itself. The first Sparkle-carrying release has to be downloaded by hand; automatic updates begin working for the release after it. Say so in the release notes rather than leaving people to discover it.
