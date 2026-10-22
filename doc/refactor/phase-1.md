# Phase 1: Gates and tooling

**Goal:** every later commit is checked by one command with short output, the payload build can't silently go stale,
a baseline exists to compare against, and the docs agents rely on match the code.

**Prerequisites:** none. **Phase gate:** `make ci` (added by P1.1).

| ID | Title | Depends on |
|---|---|---|
| P1.1 | `scripts/ci.sh`, `make ci-quick` and `make ci` | — |
| P1.2 | OSAXEmbed enumerates its inputs | P1.1 |
| P1.3 | Baseline measurements | P1.1 |
| P1.4 | Fix documentation drift and add the refactor plan to AGENTS.md | — |

---

## P1.1 `scripts/ci.sh`, `make ci-quick` and `make ci`

**Why:** the gates are spread across `make`, `make test`, `make install`, `make osax-test` and `make check-build`, and
their output is long.

**Steps**

1. Create `scripts/ci.sh` (bash, `set -euo pipefail`), taking one argument: `quick` or `full`.
   - **quick** runs `make` (debug build), then `make test`.
   - **full** runs the quick steps, then `make install` (release build; it installs nothing), `make osax-test` and
     `make check-build`.
   - Use the `SWIFT` and `SWIFT_FLAGS` variables the makefile passes through.
2. For each step, write the full output to `.build/ci/<step>.log`; `.build/` is already git-ignored, so check
   `.gitignore`. Print one line per step: `PASS|FAIL <step> <seconds>s <log path>`.
3. Warnings fail the gate. After each build or test step, search its log for compiler and linker warnings:
   `grep -E '(^|/)[^ ]+:[0-9]+:[0-9]+: warning:|^ld: warning:|warning: ' | grep -v -F -f scripts/ci-warning-allowlist.txt`.
   - Create `scripts/ci-warning-allowlist.txt` empty, with a comment header explaining that each entry needs a
     reason.
   - If the current tree already produces warnings, don't add them to the allowlist silently: list them in the P1.1
     notes in `status.md`, and add each to the allowlist with a reason comment only if it is noise outside the
     repository (for example SwiftPM resolution chatter).
4. On failure, print the step's `error:` lines (at most 30), the matching warning lines, and the last 40 lines of its
   log. Exit non-zero.
5. For the test step, print a one-line summary of the Swift Testing result: the line containing `Test run with`.
6. In the `makefile`, add `ci-quick` and `ci` targets that call `bash $(SCRIPT_PATH)/ci.sh quick|full`, and add both to
   `.PHONY`.
7. Document the targets:
   - `AGENTS.md` "Commands": one line each.
   - `doc/building.md`: a short "CI gates" paragraph naming the log directory and the allowlist.

**Acceptance**

- `make ci-quick` passes on the current tree and prints at most about 10 lines when green.
- A deliberately broken file makes it fail with the error shown. Try it and revert by hand; don't commit the break.
- `make ci` passes.

**Gate:** `make ci`. **Commit:** `P1.1 Add ci-quick and ci gates with concise logs`.

---

## P1.2 OSAXEmbed enumerates its inputs

**Why:** `Plugins/OSAXEmbed/OSAXEmbed.swift` lists its 12 inputs by hand. A new payload file that is missing from the
list can produce a stale embedded payload without any error. `doc/swift-conventions.md` already says "`OSAXEmbed`
must declare every native input".

**Steps**

1. In `createBuildCommands`, keep the two scripts (`scripts/build-osax.sh`, `scripts/osax-toolchain.sh`) as explicit
   inputs.
2. Replace the hand-written `osax/` entries with a recursive enumeration of `osax/` using `FileManager`.
   - Include the extensions `m`, `c`, `h`, `S`, `swift` and `modulemap`.
   - Exclude `osax/.build/`, `osax/testing/` and `osax/Package.swift`, which are not payload inputs. Check
     `scripts/build-osax.sh` for every file it actually reads, and include anything else it reads.
   - Exclude `osax/Version.c` and `osax/include/` only if `build-osax.sh` doesn't read them. Read the script and decide.
3. Sort the list so the build graph is deterministic.
4. Make sure the enumeration can't pick up generated files: `osax/payload_bin.c` and `osax/loader_bin.c` must never
   exist in sources (`check-build.py` asserts this).

**Acceptance**

- `make check-build` passes.
- After `touch osax/core/swift/Core.swift`, `make` rebuilds the payload; the build log shows the "Build and embed"
  step.
- A second `make` without changes doesn't rebuild it.
- Note in the commit body which files the enumerated list contains that the old list didn't.

**Gate:** `make ci`. **Commit:** `P1.2 Enumerate the scripting addition inputs in OSAXEmbed`.

---

## P1.3 Baseline measurements

**Why:** later phases claim performance and safety gains, so record the numbers to compare against.

**Steps**

1. Record the following in a new section "Baseline (P1.3)" at the end of `status.md`, with the commit hash:
   - Test count and durations from `make ci` (`Test run with … tests`, and the step times from `ci.sh`).
   - `swift test --sanitize=thread` and `swift test --sanitize=address`: pass or fail and duration. If either fails,
     record the failing tests and the first error lines. Don't fix anything in this subphase; add the failures under
     "Discovered".
   - The `make coverage` total line coverage, and the 10 `Sources/` files with the lowest coverage.
   - Release binary size: `stat -f %z bin/yabai` after `make install`.
   - Counts of the following, using the same grep for each:
     - `grep -rn '!' --include=*.swift Sources | grep -v '!=' | wc -l` (a rough force-unwrap count);
     - `unsafeBitCast`;
     - `Unmanaged`;
     - `preconditionFailure|fatalError|fatal\(`.
2. Change no source files.

**Acceptance:** the baseline section exists and holds every value above, and each value names the command that
produced it.

**Gate:** `make ci-quick`. **Commit:** `P1.3 Record the refactor baseline`.

---

## P1.4 Fix documentation drift and add the refactor plan to AGENTS.md

**Why:** agents trust the docs, and some no longer match the code.

**Steps**

1. `doc/architecture.md`: replace C names that no longer exist with the Swift symbols that do the job. Grep each one,
   for example `treeVisibleWindowCount`, `window_manager_find_tree_view`, `window_manager_tree_focus_*`,
   `tree_raise_tabs` and `tree_card_did_order`. If no counterpart exists, drop the mention.
2. `doc/testing-refactor.md`: the known-issues section mentions `withKnownIssue` cases, but none remain
   (`grep -rn withKnownIssue tests` is empty). Update that section to the current state.
3. Comments:
   - Remove stale "while the handlers are C" style comments (`grep -rn "handlers are C\|the C code\|in C,"
     Sources`).
   - Reword doc comments that still use C names, which `doc/swift-conventions.md` forbids, in
     `YabaiCore/ViewArea.swift`, `Area.swift`, `SpaceList.swift` and `MessageParse.swift`. Grep those files for
     `_` + lowercase C-style identifiers inside `///` comments.
   - Keep every `// NOTE:` that records macOS behavior.
4. `AGENTS.md`, table "Read first, by topic": add the row
   `| work on the refactor plan | doc/refactor/overview.md, doc/refactor/status.md |`.

**Acceptance:** the identifiers above no longer appear in docs or comments, and only comments and docs changed: no
code tokens differ. Verify with `git diff --stat` and by reading the diff.

**Gate:** `make ci-quick`. **Commit:** `P1.4 Fix documentation drift and link the refactor plan`.
