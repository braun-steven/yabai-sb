# Phase 14: Replace make with just

**Goal:** a `justfile` replaces the `makefile`. Every recipe keeps its target's behavior, the scripts, the docs and
`update-yabai-fork` call `just`, and the `makefile` is deleted. The user decided this on 2026-10-22: install `just`
with Homebrew, delete the makefile without a shim, and let the agent update `~/.local/bin/update-yabai-fork`.

**Prerequisites:** phases 1 to 13 closed. **Phase gate:** `make ci` until P14.3 deletes the makefile, then `just ci`.

| ID | Title | Depends on |
|---|---|---|
| P14.1 | Install just and add a `justfile` with every make target | — |
| P14.2 | Scripts and `update-yabai-fork` call just | P14.1 |
| P14.3 | Delete the makefile and move the docs to just | P14.2 |

---

## P14.1 Install just and add a `justfile` with every make target

**Why:** `just` recipes take real arguments, which removes the makefile pitfalls: the `.NOTPARALLEL` workaround and
`COVERAGE_FILTER='WindowManager\+Tree'` losing its backslash (`doc/live-testing.md`).

**Steps**

1. If `command -v just` finds nothing, run `brew install just` once (no sudo; the user approved it). Record the version
   (`just --version`) in the P14.1 notes.
2. Create `justfile` in the repository root with one recipe for each makefile target, and the same behavior:
   - Settings: `set shell := ["bash", "-euo", "pipefail", "-c"]`, `set positional-arguments` only if a recipe needs it.
   - Variables: `swift := env("SWIFT", "xcrun swift")` and `swift_flags := env("SWIFT_FLAGS", "")`, so both can be
     overridden from the environment as with make. Export `SDKROOT` with the same default as the makefile
     (`xcrun --sdk macosx --show-sdk-path`), unless the environment already sets it.
   - `build` is the first (default) recipe and replaces `all`: the debug build, published atomically to `bin/yabai`
     through `bin/.yabai.tmp` exactly as the makefile does. `install`, `asan` and `tsan` share that publish logic through
     a private helper recipe (`[private]`) that takes the build flags as a parameter. Keep the sanitizer scratch paths
     (`.build/asan`, `.build/tsan`) and flags.
   - Keep the names `install`, `asan`, `tsan`, `prepare`, `test`, `lint`, `ci-quick`, `ci`, `coverage`,
     `check-build`, `osax-test`, `osax-payload`, `man`, `icon`, `publish`, `archive`, `sign`, `clean-build` and
     `clean`. Don't rename `install` to `release`; that is a backlog item.
   - `test` and `osax-test` take extra SwiftPM arguments as a variadic parameter (`*args`), so `just test --filter
     Golden` works. `coverage` takes the filter as an optional parameter: `just coverage 'Con|TreeView'`.
   - `archive` runs `man`, `install`, `sign` and `icon` as dependencies or `just` calls, in the makefile's order.
   - Comments: keep the makefile's comments that explain why, attached to the matching recipe.
3. Don't touch the makefile, the scripts or the docs yet.

**Acceptance**

- `just --list` shows every recipe with its comment; `just --fmt --check --unstable` passes.
- `just` and `make` both publish a working `bin/yabai` (`bin/yabai --version` prints the same version).
- `just test --filter Golden` runs only the Golden tests.
- `just coverage 'WindowManager\+Tree'` shows the `WindowManager+Tree.swift` row, which make loses.
- `SWIFT_FLAGS='--filter Golden' just test` honors the environment variable.
- `just --dry-run archive` and `just --dry-run publish` print the same commands as `make -n archive` and
  `make -n publish`, except for the `just` calls. Compare them in the commit body; don't run `archive`, `publish` or
  `sign`.
- `just ci` passes (it still calls `scripts/ci.sh`, which still runs make; that is fine for this subphase).

**Gate:** `make ci` and `just ci`. **Commit:** `P14.1 Add a justfile with every make target`.

---

## P14.2 Scripts and `update-yabai-fork` call just

**Why:** `scripts/ci.sh` and `scripts/live-tests/deploy.sh` run `make`, and so does the user's
`~/.local/bin/update-yabai-fork`. They must work before the makefile goes.

**Steps**

1. `scripts/ci.sh`: run each step with `just <recipe>` instead of `make <target>`. The `build` step runs `just build`.
   Fail with a clear message at the start if `command -v just` finds nothing. Update the header comment ("SWIFT and
   SWIFT_FLAGS come from the makefile").
2. `scripts/live-tests/deploy.sh`: `make $VARIANT` becomes `just $VARIANT`. Read the script only; never run it (rule 6).
3. Comments in `scripts/coverage.sh` and any other script that names the makefile: say `justfile`.
4. `~/.local/bin/update-yabai-fork` (outside the repository, not versioned):
   - Read the whole script first.
   - Replace `make -C "$REPO_DIR" check-build` with `just --justfile "$REPO_DIR/justfile" check-build`, and
     `make -C "$REPO_DIR" install` with `just --justfile "$REPO_DIR/justfile" install`. `--justfile` runs recipes
     in the justfile's directory, so `-C` is not needed.
   - The script may run with a reduced `PATH` (it calls `sudo` later). Resolve `just` once near the top, for example
     `JUST=$(command -v just || echo /opt/homebrew/bin/just)`, and fail with the script's own `fail` function if it
     isn't executable.
   - Back it up first to `~/.local/state/yabai/update-yabai-fork.before-just`. Never run it: it needs sudo and a real
     terminal.
   - Run `bash -n ~/.local/bin/update-yabai-fork` to check the syntax. Put the before and after of the changed lines in
     the commit body, because the file is not in git.
5. Add a live check: the user runs `update-yabai-fork` in a real terminal after this phase, and it builds through just.

**Acceptance**

- `just ci` passes, and `.build/ci/build.log` shows that SwiftPM ran through `just build` (no make in the logs).
- `grep -rn 'make ' scripts` finds no make invocation; English uses of "make" are fine.
- `bash -n` passes for `scripts/ci.sh`, `scripts/live-tests/deploy.sh` and `~/.local/bin/update-yabai-fork`.

**Gate:** `just ci`. **Commit:** `P14.2 Run just from the CI, deploy and update scripts`.

---

## P14.3 Delete the makefile and move the docs to just

**Why:** two build entry points drift apart. The user chose a clean switch with no shim.

**Steps**

1. `git rm makefile`.
2. Replace every make invocation in living docs with the just equivalent. Find them with
   `git grep -n -E '(^|[^a-z_])make( |$|`|\))' -- ':!doc/refactor' ':!CHANGELOG.md'`, then read each hit; English
   "make" stays.
   - `AGENTS.md` "Commands" and every other mention (`make` → `just`, `make test SWIFT_FLAGS=…` → `just test …`,
     `make coverage COVERAGE_FILTER=<re>` → `just coverage <re>`).
   - `README.md` build section, `doc/building.md` (the table, "CI gates", and drop the `.NOTPARALLEL` remark if it no
     longer applies), `doc/live-testing.md` (also remove the `\+` backslash pitfall, which just doesn't have, and say
     why in one line), `doc/osax-prototypes.md`, `doc/payload-updates.md` and `doc/swift-conventions.md`.
   - `doc/testing-refactor.md` is a record of finished work: change only its instructions that someone would still
     follow, not its history.
   - Add a "Requirements" line to `doc/building.md` and `README.md`: `brew install just`.
3. `doc/refactor/overview.md`: the "Gates" table and the text around it say `just ci-quick` / `just ci` /
   `just install` / `just osax-test`. Don't edit the finished phase files 1 to 13.
4. `CHANGELOG.md`: one entry under the unreleased section saying that the build entry point is now `just` and the
   makefile is gone. No README "Fork changes" entry; it is tooling, not a feature.
5. Record the pitfalls that cost time in `doc/building.md`.

**Acceptance**

- `makefile` is gone, and `git grep -n -E '(^|[^a-z_])make (test|install|ci|osax|check-build|coverage|man|lint|asan|tsan|clean)'`
  outside `doc/refactor/phase-*.md`, `doc/refactor/status.md`, `doc/refactor/live-checks.md` and `CHANGELOG.md` history
  finds nothing.
- `just ci` passes from a clean `.build/ci`.
- `just man` regenerates `doc/yabai.1` with no diff.

**Gate:** `just ci`. **Commit:** `P14.3 Delete the makefile and document just`.
