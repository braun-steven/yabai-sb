# Scripting addition: boundaries, Dock evidence and live verification

The payload has one core, in Swift (`osax/core/swift/Core.swift`), and a native Dock adapter in Objective-C
(`osax/payload.m`, manual retain/release) with the loader in `osax/loader.m`. The adapter and loader stay native because
they need the private SkyLight/ObjC calls, pointer authentication and the arm64e/SIP setup. The Objective-C core, the
comparison of the two cores and their measurements were removed after the user chose Swift; they are in git at
`ae2d8630` (this file and `doc/osax-prototype-results.json`, `doc/osax-injected-results.json`,
`doc/osax-injected-checks.txt`, `doc/osax-live-compatibility.txt`).

## Implemented boundaries

- `osax/payload.m` owns private SkyLight/ObjC calls, Dock object discovery, pointer authentication, the Swift-convention
  calls into Dock and the animation instruction patch. No Dock object crosses the core API
  (`osax/core/api/include/OSAXCore.h`).
- Dock's `addSpace` and `moveSpace` are Swift methods that take self in x20. The adapter calls them through
  `__attribute__((swiftcall))` function types whose last parameter is `__attribute__((swift_context))`, which clang
  lowers to `swiftself` (x20), so the compiler sets every argument register at the call (`osax/arm64_payload.m`).
  Check a change with `otool -arch arm64e -tvV .build/osax/swift/payload`: x0–x2 and x20 are set right before each
  `blraaz`.
- `Core.swift` validates the complete message before dispatch: fixed lengths, counts, booleans, finite floats and no
  trailing bytes. A list entry is four bytes (a window id), an order entry twelve.
- Frame reads have a 1 s absolute deadline. The daemon gives a complete request 2 s including connection and reply
  (`SAConnection`). Partial transfers and EINTR resume within that deadline. A timeout does not retry the command, because
  the payload may already have applied it.
- A request is a native-endian 16-bit length, the opcode and its fields. The handshake (0x01) replies
  `version NUL attributes(4) newline`, the Dock info (0x15) `uuid NUL known(1) newline`. Every other command replies one
  status byte: 0 accepted, 1 invalid, 2 unsupported, 3 failed. A payload that closes without a status byte failed the
  command. Accepted means dispatched, not observed WindowServer completion: SkyLight can return success for a nonexistent
  window, and private void calls (`SLSMoveWindowsToManagedSpace`) can only report that they ran.
- Opcodes in use: 0x02–0x06 (space focus, create, destroy, move; window move), 0x09–0x0B (sub-level, sticky, shadow),
  0x0D (scale), 0x11 (order in), 0x12 (windows to a space), 0x14 (order list), 0x15 (Dock info). The removed numbers stay
  unused ([payload-updates.md](payload-updates.md) "Removed opcodes").

The bootstrap is assembly with named literal slots (`osax/bootstrap.S`). The loader distinguishes pthread creation,
dlopen completion and socket readiness. It waits for the worker thread ID to disappear before reclaiming code and
context, and terminates the parked Mach bootstrap first. An indeterminate timeout keeps the remote memory rather than
free storage still in use. The mocked loader tests run this control flow.

Installation checks file close, chmod and codesign results before restarting Dock. Socket startup checks the ownership
and type of an existing path and thread creation, and accepts only the same UID or root. Instruction patching
invalidates the instruction cache and reports its capability only after executable protection is restored.

## Isolated checks

```sh
just osax-payload
just osax-test
swift test --package-path osax --sanitize=address
swift test --package-path osax --sanitize=thread
swift build --package-path osax -c release --product osax-benchmark
"$(swift build --package-path osax -c release --show-bin-path)/osax-benchmark"
python3 scripts/osax/inspect_dock.py
```

The recording adapter (`osax/testing/adapter/Recorder.m`) never links SkyLight or touches real windows: it records each
dispatched message. The tests exercise every opcode, truncation, malformed counts and values, 10,000 bounded fuzz
mutations, fragmented frames, disconnections, interrupted poll, deadlines and loader failures. A rejected fuzz packet
must leave the dispatch count and digest unchanged, and a fixed digest of the fixture packets pins command order.
The benchmark measures validation/dispatch and socket round trips of this host only; it is not an injected-payload
measurement.

## Dock inspection and ownership evidence

Inspected macOS 27.0.1, build 26A434; Swift 6.4. Dock SHA-256:
`b704affba65f732ffd6676c3bb22c94abc737ee73af8bdf29a5ef02650cde33e`.
Ordinary arm64e UUID: `3BDF6A3B-866B-3C07-920C-E9E7FB57B56B`.

The `dock_spaces` signature has two candidates: 0x30a98 decodes to 0x409bb0 (**Spaces**),
and 0x6df78 to 0x409ba0 (**HotCorners**). Initialization at 0x2cf58–0x2cf78 and
0x2cfd4–0x2cff8 plus Objective-C class metadata distinguish the two. Runtime discovery now
requires a readable storage/object address, a registered class, expected selector and, for Spaces,
the `_displaySpaces` ivar. Multiple different validated objects disable that capability. Function
patterns must be unique within their bounded `__TEXT,__text` search region.

`addSpace` at 0x228cbc saves incoming x0 in x21, retains it at 0x228da0 and passes that additional
reference to its array helper at 0x228db4. Dock's caller at 0x182b60–0x182b68 passes an existing
borrowed argument. There is no release consuming the caller's initial reference. The payload now
balances its alloc/init ownership after the call. This is static evidence for this Dock binary;
repeated live create/destroy cycles must still check memory behavior. Typed, retained CF-array
creation also removes the analyzer's previous helper-type/ownership diagnostics.

The animation patch replaces `fmov d0, #0.25` at 0x227508 (the 0.25 s space slide when a window on another space is
focused) with `movi d0, #0`.

`moveSpace` at 0x18c554 runs on the payload's socket thread, between the two main-queue blocks of `do_space_move`, as
upstream does. Its direct callees, followed eight calls deep, contain no `dispatch_sync`, main-queue reference or
MainActor check (checked 2026-10-28), but indirect calls were not followed. Its only direct caller chain in Dock
(0x1001c8f6c, 0x1001ec39c, 0x1001ec20c, …) starts at indirect entry points, so the thread Dock itself uses is unknown.
Moving the call onto the main queue would deadlock Dock if anything below it waits on main; do it only with a live check.

## Live verification procedure

Read `doc/live-testing.md` first. Deploying restarts yabai and resets all layouts. Reloading the
payload restarts Dock. The agent must restore the installed binary after its checks.

The compatibility wrapper refuses existing test apps and requires empty spaces 4, 5 and 13. It
saves config, focus, visible spaces and test-space layouts. It uses 13 because 12 contains user
windows on this machine. Cleanup stops the test service before closing its disposable apps,
avoiding the separately documented destruction/frame-grouping and late AX callback crashes.
Immediately follow cleanup with `deploy.sh restore`, then the snapshot restore action.
With one connected display, the standard suite checks sending/focusing a window on another space;
the extra suite explicitly skips cross-display container warp and swap. Calculator placement uses
the current display geometry. Native space shortcuts remain skipped when disabled by the user.

```sh
python3 scripts/osax/compatibility.py snapshot --state /tmp/yabai-osax-live-state.json
python3 scripts/osax/compatibility.py setup --state /tmp/yabai-osax-live-state.json
python3 scripts/osax/compatibility.py run --state /tmp/yabai-osax-live-state.json --label baseline
python3 scripts/osax/compatibility.py extra --state /tmp/yabai-osax-live-state.json --label baseline
bash scripts/live-tests/deploy.sh install
# Repeat run/extra against the OLD loaded payload before reloading.
```

Only the user reloads the payload, in a real terminal, while the corresponding daemon is installed:

```sh
sudo ~/.local/bin/yabai --load-sa
sudo ~/.local/bin/yabai --load-sa
yabai -m query --scripting-addition
```

The query must show `is-current: true`, every capability true and `dock-build-known: true`
(`python3 scripts/live-tests/sa_version.py` prints the version and attributes `0x5f` without the daemon). Then repeat
run/extra, and check tab and order-list ordering, scratchpad show/hide, and repeated disposable space creation and
destruction. Record daemon and Dock PIDs, new crash reports and the warmed Dock footprint before and after each block.
Do not send malformed traffic to Dock; those cases belong to the isolated recording host.

`python3 scripts/osax/runtime.py --out /tmp/swift-runtime.json` checks that a request for a nonexistent space returns
failed (3), records 3 × 250 socket round trips of a no-op layer message, and creates and destroys 50 empty spaces with
Dock footprint samples. It turns `space_layout` off for the probe and restores it, and only removes spaces it created.
Footprint samples are coarse observations, not an object leak proof. Round trips include kernel/socket scheduling and
SkyLight; they do not measure visible-frame latency.

Finally clean up, restore the installed binary and restore the saved state:

```sh
python3 scripts/osax/compatibility.py cleanup --state /tmp/yabai-osax-live-state.json
bash scripts/live-tests/deploy.sh restore
python3 scripts/osax/compatibility.py restore --state /tmp/yabai-osax-live-state.json
python3 scripts/live-tests/sa_version.py
```

The restored binary may predate `query --scripting-addition`, so use `sa_version.py` here.

The restored daemon's startup may reinstall/reload its older payload. Verify its version; a different
installed payload may need the user's terminal reload again. Do not leave an experimental payload
active while claiming the original environment has been restored.
