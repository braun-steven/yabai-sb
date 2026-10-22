# Scripting-addition prototype comparison

The Swift core (2.1.37) is the only implementation, selected by the user after the isolated and
injected comparison below. The unused Objective-C core, legacy framing benchmark and selection
options have been removed. The native Dock adapter and loader still require Objective-C/C and
the existing SIP/arm64e setup. The choice favors Swift state management and consistency with the
daemon, not a demonstrated visible speed gain. Historical comparison sources are in commit
`dd557cb`; the recorded results below describe that revision's two-core harness.

## Implemented boundaries

- `osax/payload.m` owns private SkyLight/ObjC calls, Dock object discovery, pointer authentication,
  register-specific calls and the animation instruction patch. No Dock object crosses the core API.
- `osax/core/swift/Core.swift` implements validation, frame I/O, replies and synchronized opacity
  state. One 8 ms timer calls the core;
  elapsed monotonic time determines interpolation. Immediate opacity cancels a pending fade.
- Validation completes before dispatch. Fixed fields, counts, booleans, floating values and trailing
  bytes are checked. A skipped proxy entry is four bytes; a nonzero window includes its proxy ID.
- Frame reads have a 1 s absolute deadline. The daemon gives a complete request 2 s including
  connection and reply. Partial transfers and EINTR resume within that original deadline. A timeout
  does not retry the command, because the backend may already have applied it.
- Requests retain their native-endian 16-bit length, opcode values and field encoding. Handshake
  replies retain `version NUL attributes newline`. Non-handshake replies add one optional byte:
  0 accepted, 1 invalid, 2 unsupported, 3 failed. Available SkyLight/transaction error codes propagate
  to failed replies; private void calls can only report that they were invoked. SkyLight can also
  return success for a nonexistent window (observed for `SLSSetWindowAlpha`); acceptance cannot
  establish that the target existed or changed. An old daemon
  already discards that byte. An old
  payload closes without one; the new daemon represents this as **legacy/unconfirmed**, preserving
  the old Bool API. Accepted means dispatched or queued, not observed WindowServer completion.
- Swift is version 2.1.37. The embedded bundle, loader and daemon's version accessor use that
  version; the removed Objective-C prototype used 2.1.35.

The bootstrap is now assembly with named literal slots, rather than a byte string with numeric
patch offsets. The loader distinguishes pthread creation, dlopen completion and socket readiness.
It waits for the worker thread ID to disappear before reclaiming code/context, and terminates the
parked Mach bootstrap first. An indeterminate timeout intentionally retains remote memory instead
of freeing storage still in use. The mocked loader tests execute this actual control flow.

Installation checks file close, chmod and codesign results before restarting Dock. Socket startup
checks ownership/type of an existing path, checks thread creation and accepts only the same UID or
root. Instruction patching invalidates the instruction cache and advertises its capability only
after executable protection is restored.

## Reproduce isolated checks

```sh
just osax-payload
just osax-test
swift test --package-path osax --sanitize=address
swift test --package-path osax --sanitize=thread
swift build --package-path osax -c release --product osax-benchmark
"$(swift build --package-path osax -c release --show-bin-path)/osax-benchmark"
python3 scripts/osax/inspect_dock.py
```

The benchmark now measures only Swift. The recording adapter never links SkyLight or touches real
windows. It records the complete adapter
input, including entry order, and simulates alpha. Tests exercise every opcode, truncation, malformed
counts/values, 10,000 bounded fuzz mutations, fragmented frames, disconnections, interrupted poll, deadlines,
fade replacement/cancellation, backend failures, concurrent opacity commands and loader failures.
Rejected fuzz packets must leave native dispatch counts/digests unchanged; a fixed expected trace
digest replaces cross-core comparisons for command ordering.

The historical `legacy` mode used the original framing function from commit 107feff, followed by
the shared recording adapter and Objective-C prototype fade state. Only valid input was supplied
to it. It was **not a full old-payload performance baseline**. Validation/dispatch and socket round trips are
reported separately, including p95/p99. Allocation calls use a temporary malloc logger in this
benchmark process; null means the platform did not expose an unused logger. Historical malloc
blocks, bytes and RSS included the host and both linked cores, not an injected-payload footprint;
current single-core host memory samples are not directly comparable with those values.

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
python3 scripts/live-tests/sa_version.py
```

Require 2.1.36 with attributes 0x5f, then repeat run/extra. Check opacity endpoints,
rapid fade replacement, tab/proxy ordering and repeated disposable space creation/destruction.
Record daemon/Dock PIDs, new crash reports and warmed Dock footprint before and after each block.
Do not send malformed traffic to Dock; those cases belong to the isolated recording host.

`python3 scripts/osax/runtime.py --out /tmp/swift-runtime.json` verifies actual WindowServer
alpha after immediate/fade/replacement/cancellation commands, records 3 × 250 socket round trips,
and creates/destroys 50 new empty spaces. It disables/restores space-count reconciliation and only
removes newly created spaces. Use `--window <same TextEdit id>` to match the target across runs.
The one-second request deadline tests and malformed-input cases stay outside Dock. Footprint samples
are coarse observations, not an object leak proof. Round trips include kernel/socket scheduling and
SkyLight; they do not measure visible-frame latency or isolate language overhead.

Finally clean up, restore the installed binary and restore the saved state:

```sh
python3 scripts/osax/compatibility.py cleanup --state /tmp/yabai-osax-live-state.json
bash scripts/live-tests/deploy.sh restore
python3 scripts/osax/compatibility.py restore --state /tmp/yabai-osax-live-state.json
python3 scripts/live-tests/sa_version.py
```

The restored daemon's startup may reinstall/reload its older payload. Verify its version; a different
installed payload may need the user's terminal reload again. Do not leave an experimental payload
active while claiming the original environment has been restored.

## Injected comparison, 2026-10-17

The user reloaded Objective-C 2.1.35 in Dock (pid 66897), with daemon pid 66624 and capabilities
0x5f. The laptop display is the only connected display today (1512 × 982); yesterday's baseline
used external displays, so its timing values are not a matched performance baseline. The six
fixture window IDs today are 37886, 37893, 37900, 37919, 37927 and 37936. Both injected variants
used these same windows; alpha probes targeted TextEdit window 37900.

Objective-C passed 28/28 standard checks and 5/5 available extra checks; cross-display container
warp/swap and disabled native shortcuts were explicitly skipped. Its daemon and Dock PIDs stayed
unchanged. The runtime probe passed opacity endpoints, replacement, immediate cancellation and
100 rapid replacements. A nonexistent-space request returned failure (03); an unknown-window
opacity request returned acceptance (00), exposing the native API limitation described above.
Fifty create/destroy cycles left the original space IDs intact; Dock physical footprint stayed
60.5 MB in all six samples. This does not prove an absence of small object leaks.

Three 250-command immediate-opacity blocks had median/p95/p99 round trips of
58.750/122.084/168.459, 48.792/59.167/65.417 and 35.250/51.833/94.583 µs. Warm-up/drift is visible
even within this single run. These values must not justify a language choice on their own.
Dock's initialization log confirms that the Spaces candidate was accepted, the HotCorners
candidate rejected, and the expected add/remove/move/animation addresses found. Only the unused
setFrontWindow signature was missing, as in the baseline.

The user then reloaded Swift 2.1.36/0x5f in Dock pid 69454, daemon pid 68953. It passed the same
28/28 standard and 5/5 available extra checks, every opacity/status probe and all 50 create/destroy
cycles, with unchanged PIDs. Its six footprint samples were 60.5/60.5/60.5/60.6/60.6/60.6 MB.
Both variants' 50 checked space switches had an 8 ms median CLI latency. Swift's initialization
log validates the same signature targets and rejects HotCorners.

| Core | Opacity median, µs (three blocks) | p95, µs | p99, µs |
|---|---|---|---|
| Objective-C | 58.750 / 48.792 / 35.250 | 122.084 / 59.167 / 51.833 | 168.459 / 65.417 / 94.583 |
| Swift | 59.958 / 49.375 / 38.250 | 88.125 / 58.500 / 45.750 | 128.250 / 65.334 / 62.667 |

This was one ObjC→Swift sequence, not an alternating replicated comparison. The substantial
within-variant drift and overlapping round-trip distributions prevent a causal performance claim.
Whole-Dock footprint samples also cannot isolate each payload's memory cost. Exact timings,
fixture IDs and restoration checks are in [osax-injected-results.json](osax-injected-results.json);
initialization and live-check logs are in [osax-injected-checks.txt](osax-injected-checks.txt).

Cleanup stopped the test service before app termination. `deploy.sh restore` copied and verified
the original binary, but kickstart failed because cleanup had unloaded its launchd job. Explicit
`--start-service` succeeded; the restore script now falls back to it. The original daemon pid
70579 reinstalled/reloaded payload 2.1.34/0x5f in Dock pid 70600. Verified original binary SHA-256
`9461507d649399082ce47c800b2c534a78dc8a5ad76c84b8df1904b940da065d`, all saved config values,
visible space 2 and focused window 33208. Test spaces 4/5/13 are empty and all disposable apps
are closed. Crash-report counts stayed at 11 yabai and zero Dock throughout today's tests.

## Historical comparison result

Isolated checks pass: 9 payload/loader tests under ASan and TSan, 107 main tests with each embedded
variant, warning-free arm64e prototypes and optimized daemon build, and zero clang analyzer
diagnostics. Golden IPC was not re-recorded. Exact host observations are in
[osax-prototype-results.json](osax-prototype-results.json).

Three separate processes per mode ran in alternating orders. Each dispatch block has 20,000
samples; each socket block has 1,000 samples after 200 warm-ups. All nine adapter traces have
digest `da86f660290c5770`.

| Mode | Dispatch medians, ns (three runs) | Socket medians, µs | Socket p99, µs | Allocation events per dispatch block |
|---|---|---|---|---|
| Legacy framing reference | 208 / 125 / 125 | 9.666 / 8.125 / 8.000 | 15.583 / 12.000 / 11.083 | 41,053 |
| Hardened Objective-C | 208 / 166 / 125 | 10.541 / 8.750 / 8.917 | 19.625 / 14.666 / 12.125 | 41,053 |
| Hardened Swift | 83 / 83 / 83 | 9.167 / 8.958 / 9.000 | 15.292 / 16.250 / 15.375 | 1,161 |

Live malloc bytes were 278,000 for Objective-C/reference and 245,440 for Swift. Host RSS was
6,340,608 / 6,275,072 bytes respectively. These include both linked cores and the recording host.
The built arm64e payloads are 80,488 bytes (Objective-C) and 86,968 bytes (Swift).

The Swift core reduces allocations and improves this dispatch workload, but socket distributions
overlap and the first run is slower for all modes. The baseline is only the old framing function,
not the original fade engine or an injected process. Both prototypes now pass the available checks
inside Dock, establishing feasibility of the Swift core with a native adapter on this Dock build.
The initial analysis recommended Objective-C as the default. The user subsequently chose to keep
Swift; the Objective-C prototype and selection paths have now been removed. Swift removes
manual retain/release from the small fade core and reduces host allocations, but both cores have
similar size (174 ObjC versus 171 Swift lines) and share the 1,008-line native adapter that contains
the private-ABI/ownership risk. Running another language/build path has not yet bought a measured
end-to-end advantage. A broader Swift payload migration needs replicated, alternating injected
runs, a matched full original-payload baseline and a longer soak including cross-display operations;
neither mock benchmarks nor these short live checks justify it.

Both the installed baseline and the new daemon against the
still-loaded 2.1.34 payload passed 28/28 standard and 14/14 extra live checks, with unchanged daemon
PIDs during each block. This validates backward compatibility, not the new native adapter. Live
logs are preserved in [osax-live-compatibility.txt](osax-live-compatibility.txt). The original
installed binary (SHA-256 `9461507d649399082ce47c800b2c534a78dc8a5ad76c84b8df1904b940da065d`)
and payload 2.1.34/0x5f were restored/verified afterward on October 16, before the prototype
reloads described above. Config, visible spaces and focused window were restored, with no
disposable applications left running. Cleanup did trigger
the pre-existing late AX callback crash (`window_unobserve`, pid 51362), after the successful check
blocks. See the 2026-10-17 handoff; cleanup now quiesces the service first.
