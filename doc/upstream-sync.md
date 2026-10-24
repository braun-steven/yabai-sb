# Upstream sync

yabai-sb shares no recent history with upstream yabai (`upstream` remote, asmvik/yabai): the fork is a Swift port, so
upstream changes are ported by hand, never merged. The fork's version is its own and says nothing about upstream.

## Last reviewed

- Upstream commit: **`3b463fc4`** (macOS 27 offsets, upstream `master` on 2026-09-16), after release v7.1.25 (`02de172f`).
- The three commits after v7.1.25 are in the fork as cherry-picks with identical patches: `2d743f4b` #2791 minor
  fixes (`e81fb2f5`), `dd845723` #2799 add_space for macOS 26.6 (`2ec59532`) and `3b463fc4` macOS 27 offsets
  (`e34288b6`). Their macOS 26 branches and OSAX_VERSION bumps do not apply (see below).

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
| `dd845723` | macOS 26.4+ branch of `get_add_space_pattern`; OSAX_VERSION 2.1.30 | macOS 27 only (`osax/core/api/API.c`, `sa_os_version_supported`); the 27 add_space pattern has the same bytes (`osax/arm64_payload.m`); the payload keeps its own OSAX_VERSION (`osax/common.h`) |
| `3b463fc4` | macOS 26 offsets and patterns; `verify_os_version` accepting 26 (`macOSSequoia`); OSAX_VERSION 2.1.31 | macOS 27 only; the 27 offsets and patterns are in `osax/arm64_payload.m`; the payload keeps its own OSAX_VERSION |
