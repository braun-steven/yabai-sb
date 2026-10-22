# Phase 2: Crash and robustness fixes

**Goal:** remove the crash and undefined-behavior paths that come from private-API data, AppKit internals and IPC
input. Every change here is small and local.

**Prerequisites:** phase 1. **Phase gate:** `make ci`.

| ID | Title | Depends on |
|---|---|---|
| P2.1 | Public `AXUIElementGetPid` and checked CF casts | — |
| P2.2 | Typed, length-checked SLS notification payloads | — |
| P2.3 | CPrivate hardening: KVC guard, timer, Mach-O bounds, region ownership | — |
| P2.4 | Log private-symbol availability at startup | P2.3 |
| P2.5 | IPC hardening: length cap, malformed-message reply, client timeout | — |
| P2.6 | No traps in JSON encoding and signal parsing | — |

---

## P2.1 Public `AXUIElementGetPid` and checked CF casts

**Where:**

- `AXUIElement.pid` in `Sources/Yabai/Platform/AX.swift` reads offset `0x10` of the private element struct.
- The typed attribute getters there (`stringAttribute`, `boolAttribute`, `elementAttribute`, `arrayAttribute`) use
  `unsafeDowncast`.
- `unsafeBitCast(CFArrayGetValueAtIndex(…), to: …)` is used in `Platform/SkyLight+Windows.swift` (to `CFNumber`) and in
  `WindowManager+Discovery.swift` (to `AXUIElement`).

**Steps**

1. Implement `pid` with `AXUIElementGetPid(self, &pid)`. Keep the type `pid_t`; on error return `0` only if every
   caller treats 0 as "unknown". Better: make it `pid_t?` and adapt the callers (grep `\.pid\b` on AX elements) so
   that a failure is nil, per the conventions on sentinels.
2. In each typed getter, check `CFGetTypeID(value) == CFStringGetTypeID()` (and `CFBooleanGetTypeID()`,
   `AXUIElementGetTypeID()`, `CFArrayGetTypeID()`, `AXValueGetTypeID()` for the AXValue getters) before the downcast.
   On a mismatch, return nil (false for `boolAttribute`) and log at debug level through `Logger.windows`.
3. Replace the two `unsafeBitCast` array reads:
   - Use `Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()` after a nil check and the same type-id check.
   - Or bridge the array once (`as? [AXUIElement]`), if that is not on a hot loop. The discovery loop runs once per
     application, so bridging is fine there; keep the pointer form in SkyLight if it is on a per-window hot path.
4. Add a `YabaiTests` test, outside the window server, that feeds a `CFNumber` where a string is expected through a
   small internal helper taking a `CFTypeRef`, and expects nil. Factor the type check into such a helper,
   `castAttribute<T>(_ value: CFTypeRef, typeID: CFTypeID) -> T?`.

**Acceptance:**

- `grep -n "0x10\|unsafeDowncast" Sources/Yabai/Platform/AX.swift` is empty.
- The two `unsafeBitCast` array reads are gone.
- The new test passes.

**Gate:** quick. **Commit:** `P2.1 Read AX pids through the public API and check CF types`.

---

## P2.2 Typed, length-checked SLS notification payloads

**Where:**

- `connectionNotificationHandler` in `Sources/Yabai/MissionControl.swift` switches on raw ids (1327, 1328, 808, 804,
  806, 807, 815, 816, 1202, …) and reads `data!.loadUnaligned(...)` without checking `dataLength`.
- The ids are registered as literals in `Daemon.run` (`Sources/Yabai/Yabai.swift`).

**Steps**

1. Add `enum SLSNotification: UInt32, CaseIterable` in `Sources/Yabai/Platform/SkyLight.swift`, or a new
   `Platform/SLSNotification.swift`.
   - Give each case a name that describes the event: `spaceCreated = 1327`, `spaceDestroyed = 1328`,
     `windowOrdered = 808`, `windowDestroyed = 804`, `windowMoved = 806`, `windowResized = 807`,
     `windowChanged = 815`, `windowHidden = 816`, and `1202` and any other ids by what their handlers do.
   - Give each case a `///` comment saying what the payload holds.
2. Add a pure decoding helper:
   `static func payload<T>(_ data: UnsafeMutableRawPointer?, _ length: Int, as: T.Type) -> T?`. It returns nil when
   `data == nil || length < MemoryLayout<T>.size`, and otherwise uses `loadUnaligned`.
3. Rewrite the handler as `guard let kind = SLSNotification(rawValue: type) else { return }` followed by a `switch kind`.
   Each case decodes through the helper and returns on nil, after a debug log (keep it allocation-free; it can run
   often).
4. Make registration in `Daemon.run` iterate the enum (or an explicit list of its cases), so registration and dispatch
   can't drift. Keep the registration order and any per-id conditions exactly as they are now.
5. Tests (`YabaiTests`): the helper returns nil for nil data and for short lengths, and decodes a `UInt64` and a
   `UInt32` from a buffer.

**Acceptance:** no `data!` remains in the handler, no bare numeric notification ids remain in `Yabai.swift` or
`MissionControl.swift`, and the tests pass.

**Gate:** quick. **Commit:** `P2.2 Decode SLS notifications through a typed, length-checked enum`.

---

## P2.3 CPrivate hardening: KVC guard, timer, Mach-O bounds, region ownership

**Steps**

1. **KVC guard.** In `Sources/CPrivate/Notify.m`, wrap the two `setValue:forKey:` calls (`_identityImage`,
   `_identityImageHasBorder`) in `@try { … } @catch (NSException *e) { }`. An unknown key on a future macOS then
   costs only the icon. The file uses manual retain/release (C11, MRR); don't add ARC constructs.
2. **Deprecated timer.**
   - In `Sources/CPrivate/include/CPrivate.h`, `ReadOSTimerC` uses the deprecated `AbsoluteToNanoseconds` with a
     pointer pun. Grep its Swift callers.
   - Replace them with `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` in Swift. This clock matches `mach_absolute_time`:
     it doesn't advance during sleep.
   - Delete `ReadOSTimerC` if nothing else uses it. If a caller compares the value with timestamps from another
     source, keep the units (ns) and the clock (uptime, raw) identical.
3. **Mach-O bounds.**
   - In `MachO.swift` (the symbol lookup loop), skip any entry whose `n_un.n_strx >= symtab.strsize`.
   - Bound the string comparison with `strncmp` up to the remaining table length, or check that a NUL exists within
     the table.
   - Results are already resolved once at startup, so no caching is needed.
4. **Region ownership.**
   - `CPrivate.h` declares the out-param of `CGSNewRegionWithRect` with `CF_RETURNS_RETAINED`; it is used in
     `Platform/SkyLight+Windows.swift`. Check how Swift imports it: `swift-ide-test`, or a scratch `swiftc
     -print-ast` against the module map. Alternatively, read the generated interface in Xcode's index:
     `Unmanaged<CFTypeRef>` vs a managed `CFTypeRef`.
   - If Swift receives an `Unmanaged`, the call site must call `takeRetainedValue()`. If it is managed, there's
     nothing to do.
   - Record the finding in the commit body, and as a one-line NOTE at the call site if it was non-obvious.

**Acceptance:**

- `make install` (release) succeeds.
- `grep -rn AbsoluteToNanoseconds Sources` is empty.
- The KVC calls are guarded.

**Gate:** quick + release. **Commit:** `P2.3 Harden CPrivate: guard private KVC, drop deprecated timer, bound Mach-O reads`.

---

## P2.4 Log private-symbol availability at startup

**Where:**

- `Daemon.configureSettingsAndAcquireLock` (`Yabai.swift`) resolves `_CGSGetConnectionPortById` and the mangled
  `SLSPerformAsynchronousBridgedWindowManagementOperation` through `skyLightSymbol`.
- Other runtime lookups (dlsym or Mach-O): grep `skyLightSymbol\|dlsym\|MachO\.` in `Sources/Yabai`.

**Steps**

1. Collect every runtime-resolved symbol into one table with a feature name each, for example
   `("CGSGetConnectionPortById", "window sub-level query")`.
2. After resolution, log one `Logger.daemon.notice` line listing the missing symbols with their features, or one
   `debug` line "all private symbols resolved".
3. Keep resolution order and behavior unchanged; this is logging only.
4. Mention the new log line in `doc/live-testing.md` ("Crash reports" or a new short "Startup diagnostics" bullet).

**Acceptance:** builds; the log call goes through a component logger.

**Gate:** quick + release (`Yabai.swift` calls CPrivate). **Commit:** `P2.4 Log unresolved private symbols at startup`.

---

## P2.5 IPC hardening: length cap, malformed-message reply, client timeout

**Where:**

- `readMessage` in `Sources/Yabai/IPC/MessageLoop.swift` allocates `Int(bytesToRead) + 2` from a client-supplied
  `Int32`.
- A malformed or short message closes the socket silently.
- `Client.send` in `Sources/Yabai/IPC/Client.swift` has no receive timeout.

**Steps**

1. **Length cap.** Add `static let maxMessageLength = 1 << 20` (1 MiB). If `bytesToRead > maxMessageLength`, reject it.
2. **Malformed messages.** For a rejected, short or unreadable message, write a failure response before closing:
   `Response.failureByte` followed by `"invalid message\n"`, the same framing as other failures (see `Message.swift`
   `Response`). Check how responses are written today (the yabai.ipc queue). Write the error inline on the reading
   queue only if that is where other responses are written; otherwise route it the same way. Log through
   `Logger.ipc`.
3. **Client timeout.**
   - Set `SO_RCVTIMEO` on the client socket before reading, 30 s by default, overridable with the environment
     variable `YABAI_CLIENT_TIMEOUT` (seconds, a positive integer; ignore invalid values).
   - The long default protects commands that legitimately wait, such as native fullscreen toggles.
   - When `read` returns -1 with `EAGAIN`/`EWOULDBLOCK`, print `yabai-msg: timed out waiting for a response..` to
     stderr and exit with `EXIT_FAILURE`.
   - Document the variable in `doc/yabai.asciidoc` (ENVIRONMENT or the `-m` section) and run `make man`.
4. **Tests.** Use a `socketpair` in `YabaiTests`, through an internal helper that takes an fd:
   - a length header of `maxMessageLength + 1` yields nil, or the failure response;
   - a valid message still parses.

   Run `swift test --sanitize=thread` and `--sanitize=address` (socket work).
5. Add a CHANGELOG entry: "IPC: reject oversized messages, reply to malformed ones, client timeout
   (YABAI_CLIENT_TIMEOUT)".

**Acceptance:** tests pass under both sanitizers, and the golden replay is unchanged.

**Gate:** quick + sanitizers. **Commit:** `P2.5 Cap IPC message size, answer malformed messages, time out the client`.

---

## P2.6 No traps in JSON encoding and signal parsing

**Where:**

- `preconditionFailure` in `Sources/YabaiCore/JSON.swift`, for an encoder failure.
- `preconditionFailure` in `Sources/YabaiCore/SignalCommand.swift`, for "parseSignal requires an event".
- The untyped `throws` in `YabaiCore/Query.swift`, in the internal `encode` helper.

**Steps**

1. Make the JSON encode function `throws(CommandError)`, throwing `CommandError("could not encode query json\n")`.
   Update the callers; they are query handlers that already throw `CommandError`.
2. In `SignalCommand`, replace the trap with `throw CommandError(…)`, using the same message style as other
   signal-parse failures. Check `parseSignal` for the wording used when the event is missing.
3. Make the untyped `throws` in `Query.swift` typed, consistent with the rest of YabaiCore.
4. Add tests for the signal path: a signal add without an event yields the existing failure text. Check the golden
   commands for an existing case; if one exists, nothing new is needed beyond the replay passing.

**Acceptance:**

- `grep -rn "preconditionFailure\|fatalError" Sources/YabaiCore` is empty.
- The golden replay is unchanged.

**Gate:** quick. **Commit:** `P2.6 Replace traps in JSON encoding and signal parsing with command errors`.
