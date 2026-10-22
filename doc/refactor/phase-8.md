# Phase 8: Swift strictness and diagnostics

**Goal:** the compiler enforces import hygiene and tracks unsafe code, Instruments can time events and animations,
and an optional lint target exists.

**Prerequisites:** phases 6 and 7, because they remove much of the unsafe code first. **Phase gate:** `make ci`.

Swift 6.4 is near the edge of training data. Verify setting spellings against the toolchain, as
`doc/swift-conventions.md` "Toolchain" says: `swift package describe`, a scratch package, or
`swift build -Xswiftc -help` / `swiftc -frontend -help | grep -i memory`. Don't guess them.

| ID | Title | Depends on |
|---|---|---|
| P8.1 | `MemberImportVisibility` and `ExistentialAny` | — |
| P8.2 | Strict memory safety in YabaiCore | — |
| P8.3 | Measured trials: strict memory safety in Yabai, nonisolated(nonsending) by default | P8.2 |
| P8.4 | OSSignposter intervals | — |
| P8.5 | Optional lint target | — |

---

## P8.1 `MemberImportVisibility` and `ExistentialAny`

**Steps**

1. In `Package.swift`, add `.enableUpcomingFeature("MemberImportVisibility")` and
   `.enableUpcomingFeature("ExistentialAny")` to the shared `swiftSettings`. They apply to `YabaiCore`, `Yabai` and the
   test targets that use them.
   - Check the spellings with the toolchain.
   - If a feature is already on by default in Swift 6.4 language mode, skip it and note that.
2. Fix every diagnostic: add the missing per-file imports, and write `any` where an existential is spelled bare.
3. Add a bullet to `doc/swift-conventions.md` saying that each file imports what it uses (now compiler-enforced).

**Acceptance:** clean build with both features, and `make install` passes.

**Gate:** quick + release. **Commit:** `P8.1 Enable member import visibility and explicit existentials`.

---

## P8.2 Strict memory safety in YabaiCore

**Steps**

1. Enable strict memory safety (SE-0458) for the `YabaiCore` target only.
   - The SwiftPM setting is probably `.strictMemorySafety()`; otherwise use
     `.unsafeFlags(["-strict-memory-safety"])`, which is acceptable for a local package.
   - Warnings are errors here (`treatAllWarnings`), so every diagnostic must be resolved.
2. Resolve each site:
   - prefer a safe rewrite (`Span`, `withContiguousStorageIfAvailable` without pointers, standard parsing);
   - otherwise mark it with `unsafe` and a one-line reason.
3. Record the number of sites, before and after rewrites, in the notes.

**Acceptance:** YabaiCore builds with strict memory safety, and its tests pass.

**Gate:** quick. **Commit:** `P8.2 Check memory safety strictly in YabaiCore`.

---

## P8.3 Measured trials: strict memory safety in Yabai, nonisolated(nonsending) by default

**Steps**

1. **Strict memory safety in Yabai.** Enable it on a scratch build only (don't commit the setting yet) and count the
   diagnostics per file: `swift build 2>&1 | grep -c "unsafe"`. Add the table to the notes.
   - If 150 sites or fewer: enable it and resolve them as in P8.2, preferring safe rewrites in the `Platform/` wrappers
     so that callers stay safe.
   - If more: don't enable it. Record the counts and the five worst files under "Discovered" as follow-ups.
2. **NonisolatedNonsendingByDefault (SE-0461).** Do the same trial.
   - If it compiles with 20 targeted edits or fewer (`@concurrent` on functions that must run off-actor), adopt it, and
     run the sanitizers.
   - Otherwise record the counts and skip.

**Acceptance:** each trial is either adopted with a green gate or skipped with counts in the notes. If both are skipped,
commit only the status notes.

**Gate:** quick (+ sanitizers if adopted). **Commit:** `P8.3 Adopt strict checks where cheap and record the rest`.

---

## P8.4 OSSignposter intervals

**Where:**

- There are no signposts today.
- `doc/swift-port-performance.md` and `doc/performance/` describe an external timing harness.
- The event loop dispatches in `EventLoop.handle` / `EventHandler`.
- Animations tick in `WindowAnimation.swift`.

**Steps**

1. Add `enum Signposts { static let events = OSSignposter(subsystem: "com.asmvik.yabai", category: "events"); static
   let animation = … }` in `Log.swift`. Use the subsystem string the loggers already use, and grep `subsystem`.
2. Wrap each event dispatch in `beginInterval`/`endInterval`, named with the event case name. Use a `StaticString`
   per case through a switch, or one interval name with the case in the message.
3. Wrap each animation run, and each frame tick as an event.
4. Signposts are cheap when nobody is recording; keep allocations out of the disabled path.
5. Document in `doc/live-testing.md`: record with `xcrun xctrace record --template 'Logging' --attach yabai`, or use
   Instruments' os_signpost instrument, and filter by subsystem.

**Acceptance:** builds clean, and the performance tests (if any) don't regress. Compare the `make ci` test durations
with the P1.3 baseline.

**Live check:** record 20 s of window switching with the Logging template; event intervals appear per event type.

**Gate:** quick. **Commit:** `P8.4 Add signpost intervals for events and animations`.

---

## P8.5 Optional lint target

**Steps**

1. If `swift format` exists in the toolchain (`xcrun swift format --version`), add `.swift-format` with rules matching
   the current style:
   - four spaces;
   - the existing brace style (opening braces of functions and types on their own line); check the files first;
   - line length as currently used. Measure the 99th percentile line length in `Sources/`.
2. Add `make lint` running `swift format lint --recursive Sources tests`. It does **not** belong in `make ci`.
3. Run it once and record the finding count in the notes. Don't reformat anything.
4. If `swift format` is not available, mark the subphase `skipped`.

**Acceptance:** `make lint` runs, and nothing was reformatted.

**Gate:** quick. **Commit:** `P8.5 Add an optional swift-format lint target`.
