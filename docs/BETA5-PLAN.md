# Beta.5: freshness and pull-request attention

This release combines the research's proposed beta.5 and beta.6 implementation work. The beta.4 truthfulness fixes are already on main. These notes describe implementation status, not a published release.

## Implemented

- Coalesced refresh requests, configuration/publication guards, and a worker-owned baseline for targeted refreshes.
- FSEvents invalidation with 500 ms stream coalescing, wake refresh, 60-second status fallback, and 15-minute discovery backstop.
- Configuration-scoped local snapshots, cached/stale UI, and an exact refresh-time tooltip.
- Porcelain stash counts and retained icon caches with event-driven invalidation.
- Canonical host/owner/repository identities and SHA-first matching; branch fallback uses the PR head repository. Multiple local matches remain explicit rather than choosing an arbitrary checkout.
- PR check, review, and merge-state enrichment, prioritized for local repositories. Up to 24 detail requests per poll, batches of four, with a 20-second budget checked between batches. An in-flight batch can run until the subprocess timeout. Visible rows can request missing details with four concurrent requests and a five-minute retry interval.
- Account- and organization-scoped PR caches, partial-query fallback, deduplication, and account revalidation before publishing/caching.
- Organization filters applied in the CLI query. Search increases from 50 to 1,000 results per category and warns when that ceiling is reached.
- PR reasons in repository/worktree rows; remote-only attention remains visible in Pending and keyboard navigation.
- Opt-in notifications for failing checks, requested changes, and ready-to-merge transitions. Initial snapshots do not generate transition notifications.
- A separate update arrow in the menu bar, tooltip, and accessibility description.
- Sanitized session command counters, failures/timeouts, discovery/status timings, anonymous slowest-repository duration, cache freshness, shortcut registration, and updater state/check age.

## Deliberate boundaries

PR discovery continues to use the signed-in user's authored PRs and requested reviews on github.com. This is not an organization-wide PR inbox. A PR outside those searches is not automatically discovered from a worktree. Unknown authentication identity clears displayed PR data instead of reusing another account's private cache. GitHub Enterprise and other forges remain deferred.

Checks describe the API snapshot; merge readiness requires approval, successful reported checks, a mergeable result, a clean merge state, and a non-draft PR. Gitacre never merges or changes Git state. Cached PR details are labelled after ten minutes or when the PR's update timestamp is newer.

## Automated verification

Regression coverage includes attention sections and keyboard ordering, forks and duplicate names, ambiguous SHA matches, conservative merge readiness, malformed GitHub responses, partial failures, cache account isolation, configuration-scoped local snapshots, changes during discovery, stale targeted baselines, porcelain stash parsing, and an actual filesystem event.

Run `swift test`, then `scripts/build-app.sh debug` for a local bundle smoke build.

## Release gates still requiring human or distribution work

- Observe a small beta cohort finding dirty worktrees and interpreting PR attention; confirm the next action is clear.
- Measure incremental refresh p95 and energy use on representative large repository collections. No sub-second performance claim is made by this change.
- Verify real sleep/wake, notification permissions, VoiceOver, and the Sparkle update indicator in a configured signed bundle.
- Build/sign/notarize the universal release, validate on supported macOS/architectures, and publish the release/appcast using the established release procedure.

Do not mark these gates complete based solely on unit tests. Publishing, signing, and updating the live download/feed are separate from implementing this milestone.
