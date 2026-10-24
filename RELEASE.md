# Releasing yabai-sb

yabai-sb is released as a prebuilt, signed binary on GitHub (`braun-steven/yabai-sb`) and installed through the
Homebrew tap `braun-steven/tap` (repo `braun-steven/homebrew-tap`, checked out at `~/projects/homebrew-tap`). The
user cuts releases: creating a release and pushing are outward-facing, so agents prepare the commit and stop there.

## Versioning

- yabai-sb has its own [semantic version](https://semver.org), independent of upstream yabai's (which has used 1.x
  to 7.x itself). The project and formula are named `yabai-sb`; the binary stays `yabai`.
- The version is `Daemon.version` in `Sources/Yabai/Yabai.swift`, printed as `yabai-sb-v<major>.<minor>.<patch>`.
  Tags are `v<version>` and archives `yabai-sb-v<version>.tar.gz`.
- Major: a `yabai.toml` key or `-m` command is removed or changes meaning. Minor: new features, including ported
  upstream features. Patch: fixes, including ported upstream fixes.
- The upstream release the fork has caught up with is recorded in `doc/upstream-sync.md`, never in the version.

## Cutting a release

1. Bump `Daemon.version` in `Sources/Yabai/Yabai.swift`.
2. In `CHANGELOG.md`, move the `[Unreleased]` entries under `## [<version>] - <date>`.
3. Run `just ci`, then commit and `git push` (the release must point at a commit GitHub has).
4. `just brew-release` (see below).
5. `git -C ~/projects/homebrew-tap push`. Push the tap only after the release exists, or installs fail on a missing
   download.
6. Optional: `git fetch --tags` to get the new tag locally.

## What `just brew-release` does

1. `_brew-release-check` stops unless: the tap checkout exists (`YABAI_TAP_DIR`, default `../homebrew-tap`) with
   `Formula/yabai-sb.rb`; there are no uncommitted changes to tracked files; and HEAD is on `origin/main` (after a
   fetch).
2. `just archive`: `man`, a release build (`install`), `sign` (identity `yabai-cert`), `icon` (sets the logo shown in
   the Accessibility list; `scripts/seticon.swift`), then packs `bin/yabai-sb-v<version>.tar.gz` with `bin/yabai`,
   `doc/yabai.1`, `doc/yabai.schema.json` and `examples/`.
3. `gh release create v<version>` on `braun-steven/yabai-sb`, targeting HEAD, with the tarball attached. This creates
   the tag on GitHub.
4. Writes the release URL and the tarball's SHA-256 into `Formula/yabai-sb.rb` and commits it in the tap checkout. It
   never pushes the tap.

## Checking a release

- `gh release view v<version> --repo braun-steven/yabai-sb`: the tag targets the intended commit and the tarball is
  attached.
- The formula's `sha256` matches `shasum -a 256` of the downloaded asset (`gh release download v<version> --repo
  braun-steven/yabai-sb`).
- From the extracted archive: `bin/yabai --version`, `codesign --verify bin/yabai`, `bin/yabai --check-config
  examples/yabai.toml` (the formula's test), and `--generate-completion-script bash|zsh|fish`.
- `brew audit --strict --tap braun-steven/tap` and a real `brew install` need the tap added; on this machine a brew
  install puts a second `yabai` in `/opt/homebrew/bin` next to `~/.local/bin/yabai`, so prefer another account or
  untap afterwards.

## Installing and upgrading (users)

- `brew install braun-steven/tap/yabai-sb`. It conflicts with upstream's formula (`asmvik/formulae/yabai`,
  `koekeishiya/formulae/yabai`); uninstall that first.
- Setup is in the formula's caveats: copy `examples/yabai.toml` to `~/.config/yabai/`, `yabai --start-service`,
  grant Accessibility, and for the scripting addition the sudoers line (it names `which yabai`, the Homebrew link).
- `brew update && brew upgrade yabai-sb`. After an upgrade the sudoers line needs the new hash, and Accessibility may
  need granting again (the grant is tied to the code signature).

## Pitfalls

- `Push HEAD to origin/main first`: commit and push before releasing; a GitHub release cannot target a local commit.
- `Commit or stash local changes first`: any modified tracked file blocks the release (untracked files do not).
- `just icon` used to need PyObjC (`scripts/seticon.py`, `import Cocoa`); it is a Swift script now. The icon is set
  after signing, so `codesign --verify --strict` reports "detritus" while the normal `codesign --verify` passes, as
  with upstream's releases.
- The launchd label is `com.braun-steven.yabai-sb`. `yabai --start-service` removes an old `com.asmvik.yabai` service
  only when it runs the same binary. The user's `update-yabai-fork` deploy removes the service under either label
  with `launchctl` itself, since an installed binary only knows its own label.
- A release cannot be re-cut under the same tag: delete the GitHub release and tag first (`gh release delete
  v<version> --cleanup-tag`), or bump the patch version.
