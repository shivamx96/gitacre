# gitacre

gitacre is a native macOS menu-bar companion for unfinished local Git work and pull requests that need attention.

The current prototype provides:

- repository discovery under configurable folders;
- worktree-aware staged, unstaged, untracked, ahead/behind, and operation status;
- Pending and All repository views;
- GitHub CLI authentication detection without reading or storing its token;
- pull requests opened by you and awaiting your review;
- a custom native menu-bar panel with compact rows, worktree disclosure, and a restrained warm-neutral design system;
- a five-section settings window for repositories, GitHub, terminals, appearance, and diagnostics;
- keyboard navigation, a global Option-Command-G shortcut, and light/dark appearance support.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer
- GitHub CLI for the optional Pull Requests view

## Run during development

```sh
swift run Gitacre
```

## Build the app bundle

```sh
scripts/build-app.sh
open build/gitacre.app
```

gitacre looks for `gh` in common Homebrew locations and uses the active `github.com` account. Local repository monitoring works without GitHub or network access.

## Website

The static product site and its sanitized, real-app screenshots live in [`website/`](website/). It has no build step or runtime dependencies.

## Releases

Release builds are universal, Developer ID-signed, notarized, and packaged as a disk image. See [`docs/RELEASING.md`](docs/RELEASING.md) for the credential setup and release procedure.
