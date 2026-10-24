# Upstream sync

yabai-sb shares no recent history with upstream yabai (`upstream` remote, asmvik/yabai): the fork is a Swift port, so
upstream changes are ported by hand, never merged. The fork's version is its own and says nothing about upstream.

## Last reviewed

- Upstream release: **v7.1.25** (`02de172f`). Its changes are in the fork (CHANGELOG `[7.1.25]` and earlier).
- Not yet reviewed (upstream `master` after v7.1.25):
  - `2d743f4b` #2791 minor fixes
  - `dd845723` #2799 fix scripting-addition add_space for macOS 26.6 Apple Silicon
  - `3b463fc4` macOS 27 offsets

## Reviewing upstream

1. `git fetch upstream` and list the new commits: `git log --oneline <last reviewed>..upstream/master`.
2. For each change, port it (CHANGELOG entry "Port upstream #<issue>: …" under the right section) or record it below
   with the reason it does not apply.
3. Update "Last reviewed" in the same commit as the port.

## Skipped upstream changes

Changes that do not apply to the fork, with the reason. Typical reasons: the `bsp`/`stack` layouts and the yabairc are
removed (`tree` and `yabai.toml` replace them), and macOS versions before 27 and x86_64 are not supported.

| Upstream | Change | Reason |
|---|---|---|
