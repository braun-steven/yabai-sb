# Phase 3: Scripting addition hardening

**Goal:** the payload costs nothing while idle, never patches code in a Dock build it doesn't know, never traps on
malformed input, and the daemon only talks to a socket owned by the user.

**Prerequisites:** phase 2. **Phase gate:** `make ci`, plus `swift test --package-path osax --sanitize=thread` and
`--sanitize=address`.

Read `doc/payload-updates.md`, `doc/osax-prototypes.md` and `doc/live-testing.md` "Scripting addition" first. The
payload is built without ARC (`#error` guard in `payload.m`) and uses MRR, as does `loader.m`.

**`OSAX_VERSION`** (`osax/common.h`, currently `2.1.36`): the first subphase that changes payload behavior bumps the
patch number once, and records `osax_bumped: <new version>` on the phase line in `status.md`. Later subphases in this
phase don't bump again. Update every place the version is documented: grep the old version string in `doc/` and
`tests/`.

| ID | Title | Depends on |
|---|---|---|
| P3.1 | Fade timer runs only while fades are active | — |
| P3.2 | Gate the Dock animation patch on known Dock UUIDs | — |
| P3.3 | Guarded reads in the payload core | — |
| P3.4 | Daemon checks the payload socket's owner | — |

---

## P3.1 Fade timer runs only while fades are active

**Where:**

- `start_daemon` in `osax/payload.m` creates `fade_timer` on the `yabai.sa.fade` serial queue with an 8 ms interval,
  and resumes it forever.
- `swiftTick` in `osax/core/swift/Core.swift` interpolates the fades stored in the `fades` Mutex.

**Steps**

1. Core (`Core.swift`):
   - `sa_swift_tick` returns `Bool`, true while fades remain after the tick.
   - Add `@_cdecl("sa_swift_has_fades") public func swiftHasFades() -> Bool`.
   - Update `OSAXCore.h` and the `sa_core_*` macros.
   - Exports must be `public` (see swift-conventions "Optimized Swift C exports").
2. Native side (`payload.m`):
   - Create the timer suspended. Keep a `static bool fade_timer_running`, accessed only on the fade queue.
   - Add `ensure_fade_timer()`. It `dispatch_async`s onto the fade queue and resumes the timer if it isn't running.
     Call it after a fade opcode (opacity fade, opcode 8) was accepted. Find where opcode 8 reaches
     `sa_core_opacity`/`sa_swift_opacity`, and call it only when that returned true and the duration is > 0.
   - In the timer handler: `if (!sa_core_tick(sa_clock_ns())) { dispatch_suspend(fade_timer); fade_timer_running =
     false; }`.
   - Keep `dispatch_suspend` and `dispatch_resume` balanced. A suspended dispatch source must be resumed before it is
     cancelled or released; check the failure path in `start_daemon`, which today calls cancel and then resume.
   - Set the timer leeway to 1 ms as now.
3. Tests in `osax/testing/tests/PayloadTests.swift`, against the recording backend:
   - after a fade completes, `sa_swift_has_fades()` is false and `sa_swift_tick` returned false;
   - with an active fade, `sa_swift_tick` returns true.
4. Bump `OSAX_VERSION` (see above).
5. Add a short note in `doc/payload-updates.md`: "the fade timer is armed only while fades run".

**Acceptance:**

- `make osax-test` passes, including under both sanitizers (`swift test --package-path osax --sanitize=thread` and
  `--sanitize=address`).
- No timer fires while there are no fades; check by reading the code.

**Live check:** after reloading the payload, `window_opacity on` with a non-zero `window_opacity_duration` still fades.
Dock shows no constant 125 Hz wakeups (`sudo powermetrics --samplers tasks -n 1 | grep -i dock`, or Activity Monitor
"Idle Wake Ups" for Dock) while idle.

**Gate:** quick + payload + sanitizers (osax). **Commit:** `P3.1 Arm the payload fade timer only while fades run`.

---

## P3.2 Gate the Dock animation patch on known Dock UUIDs

**Where:**

- `verify_os_version` in `payload.m` accepts any macOS 27.x.
- `init_instances` patches 4 bytes at `animation_time_addr` (instruction `0x2f00e400`) after a pattern match and sets
  `animation_time_patched`.
- The attribute bit `OSAX_ATTRIB_ANIM_TIME` (`common.h`) is reported to the daemon.
- `doc/osax-prototypes.md` records the validated Dock UUID(s), for example `3BDF6A3B-866B-3C07-920C-E9E7FB57B56B`.

**Steps**

1. Read Dock's `LC_UUID` from `_dyld_get_image_header(0)`: iterate the load commands for `LC_UUID`.
2. Add `static const char *known_dock_uuids[]` holding the validated UUIDs from `doc/osax-prototypes.md`, all of them
   if several are documented.
3. Apply the code patch only if the UUID is in the list. Otherwise:
   - log `[yabai-sa] unknown Dock build <uuid>; animation patch skipped`;
   - leave `animation_time_patched` false, so `OSAX_ATTRIB_ANIM_TIME` is not reported.
   Function-pointer lookups (add/remove space, set front window) stay pattern-gated as today; only the code write is
   gated.
4. On the daemon side, check how the missing `OSAX_ATTRIB_ANIM_TIME` bit is reported (`ScriptingAddition.swift`, where
   it compares attributes). If a missing bit makes `--load-sa` or startup report a failure, make that specific bit
   produce a warning ("space animation patch unavailable for this Dock build") instead of a failure. Don't change the
   other bits.
5. Document in `doc/payload-updates.md` how to add a new Dock UUID after validating a new macOS build:
   - where the list lives;
   - which live checks are required (refer to `osax-prototypes.md`).
6. Bump `OSAX_VERSION` if P3.1 hasn't.

**Acceptance:** `make osax-test` passes, and the daemon-side handling is covered by a unit test. `ScriptingAdditionTests`
probably has an attribute-mask test to extend; check.

**Live check:** after reloading the payload on the current Dock, the log (`log show --predicate 'process == "Dock"'
--last 2m | grep yabai-sa`) shows the patch applied, and `python3 scripts/live-tests/sa_version.py` still reports
`0x5f`.

**Gate:** quick + payload. **Commit:** `P3.2 Patch Dock code only on validated Dock builds`.

---

## P3.3 Guarded reads in the payload core

**Where:** `osax/core/swift/Core.swift`.

- `swiftValidate` uses `cursor.take(UInt8.self)!`, `cursor.take(Float.self)!` and unchecked `message[25]`/`message[5]`
  subscripts, which rely on earlier length checks.
- `swiftTick` uses `state[wid]!`.
- `import Foundation` may be unused.

**Steps**

1. Replace every `!` with `guard let … else { return false }`, or `continue` in the tick loop.
2. Read the flag bytes through the cursor (`cursor.offset = 25; guard let flag = cursor.take(UInt8.self)`) instead of
   subscripting the raw pointer.
3. Try removing `import Foundation`. Keep it only if the build fails without it, and note why.
4. Optional: if `RawSpan` is available in the toolchain the payload uses (`scripts/osax-toolchain.sh`; a scratch build
   decides), rewrite `Cursor` over `RawSpan`. Skip this if it needs a newer deployment target or adds runtime
   dependencies to the arm64e dylib.
5. Extend the fuzz test in `PayloadTests.swift`: truncated messages for every opcode (length 1 to expected−1) must
   validate as false without crashing.
6. Bump `OSAX_VERSION` only if P3.1/P3.2 haven't. Behavior should be identical, but the payload binary changes.

**Acceptance:**

- `grep -n '!' osax/core/swift/Core.swift | grep -v '!=' | grep -v '!cursor\|!sa_\|!alpha\|!duration'` shows no
  force unwraps; check what remains by hand.
- `make osax-test` passes under both sanitizers.

**Gate:** payload + sanitizers (osax) + quick. **Commit:** `P3.3 Validate payload messages without force unwraps`.

---

## P3.4 Daemon checks the payload socket's owner

**Where:** `SAConnection.connect` (`Sources/Yabai/SAConnection.swift`) connects to the payload socket path without
checking it. The payload side checks ownership in `start_daemon`: `lstat`, `S_ISSOCK`, and `st_uid == getuid()`.

**Steps**

1. Before `connect`, `lstat` the path. Require `S_ISSOCK`, and an `st_uid` equal to `getuid()`, or, when running as root
   (`--load-sa` under `sudo`), equal to the uid of the console user: use `SUDO_UID` if set, otherwise accept any
   non-root owner. On mismatch, return false and log through `Logger.sa`, or whatever the SA component logger is called
   (grep `Logger\.` in `ScriptingAddition.swift`).
2. Put the check in a pure helper, `static func isTrustedSocket(mode: mode_t, owner: uid_t, uid: uid_t, sudoUID:
   uid_t?) -> Bool`, and unit-test its truth table in `SAConnectionTests`.

**Acceptance:** the tests pass under both sanitizers (`swift test --sanitize=thread` and `--sanitize=address`, socket
code), and the golden replay is unchanged.

**Gate:** quick + sanitizers. **Commit:** `P3.4 Connect only to a payload socket owned by the user`.

---

## Phase close

Add one combined live check for the phase:

- the user reloads the payload (two runs of `sudo ~/.local/bin/yabai --load-sa` after `update-yabai-fork`);
- `sa_version.py` reports the new `OSAX_VERSION` and attributes `0x5f`;
- space create, destroy and move, window opacity fades and space switching without animation all still work.
