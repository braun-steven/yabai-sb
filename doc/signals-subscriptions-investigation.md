# Signals and subscriptions cleanup

Investigated on 2026-10-28 from `0366b344`; implemented in branch
`investigate-signals-subscriptions` after advancing onto `main` at `19d602d4`.
The original checkout's unrelated changes were left untouched.

## Result

The existing shared snapshot design is retained. Handlers capture values on `@WM`, flush after
handling each event, launch matching shell actions and publish to connected clients independently
of shell filters. Socket transport uses the committed IPC v2 `IPCConnection` implementation.

Five cleanups address the main sources of unnecessary complexity:

1. `PendingSignal.matches` uses `RulePattern.admits`, removing duplicate exclusion logic and
   inverted dispatch predicates. `SignalTable.signals(for:)` distinguishes shell actions from
   connected subscribers.
2. Signal parsing is private and concrete. Required command strings are constructed only after
   the existing scanner reports all errors; there are no generic event resolvers or mutable
   output parameters. Diagnostic text/order and repeated-key behavior remain unchanged.
3. `SignalEvent` pairs each event with its required associated values. An exhaustive switch
   captures snapshots without optional subject projections or subject force unwraps. Capture
   still occurs after the interest check and before models can be mutated or destroyed.
4. Signal dispatch injects subscription interest as well as publication. Each subscriber also
   receives its owner's termination callback. Local registry tests no longer enqueue removal
   events against the shared registry. Atomic termination permits one notification per client.
5. String-backed event names replace integer storage indices. Dictionary buckets are traversed
   in declaration order for public output and numeric selectors, and empty buckets are removed
   to preserve config-reconciliation equality. Labeled signal replacement still appends to the
   destination type; rule replacement retains its different ordering semantics.

`EventSubscriber.enqueue` is now explicitly `@WM`, enforcing its single-producer backlog
contract. Writes remain on each client's serial queue. Acknowledgements precede events, encoded
frames are shared across matching clients, and the 1 MiB backlog and five-second absolute write
deadline are unchanged. Shutdown wakes a stalled writer; connection ownership prevents fd reuse
while queued writes retain it.

## Compatibility decisions

- Keep the existing event names, declaration order, environment argument order, signed ID
  formatting, string-valued event fields and IPC framing.
- Preserve filter capabilities, the nil-title fallback and reduced metadata of destroyed
  windows/removed spaces/displays. Window titles are cached, not fetched from AX at capture time.
- Preserve the exact `Double(Float(0.05))` termination-focus threshold; the helper takes elapsed
  time explicitly so boundary tests do not depend on scheduling.
- Change internal Swift APIs without keeping unused compatibility wrappers. No CLI, config,
  schema, payload, version or live-daemon migration is needed.
- Keep `posix_spawn` fire-and-forget behavior, with no new process completion guarantees.

No generic event bus, subscriber indexes, cached interest counts, idle-disconnect monitoring or
spawn-failure behavior changes were introduced. They add separate state or behavior rather than
remove redundant implementation.

## Validation

The rebased baseline passed 40 focused tests with no warnings. Regression coverage now includes
pattern inclusion/exclusion and invalid patterns; exact parser errors and repeated fields; table
normalization, replacement and public type ordering; typed capture, destroyed metadata and model
mutation after capture; termination timing boundaries; subscriber-only delivery; independent
registries and concurrent exactly-once termination. Existing transport tests cover ordered
acknowledgements, event filtering, closed peers and backlog termination.

Run the focused suite with:

```sh
xcrun swift test --filter '([Ss]ignal|[Ss]ubscrib|[Ee]ventJSON)'
```

Validation completed with Apple Swift 6.4 and the macOS 27 SDK on arm64:

- Focused suite: 51 tests passed.
- `just ci-quick`: debug build, CLI smoke checks, script tests and all 895 Swift tests passed.
  Golden IPC responses, config reconciliation/dumping and schema checks passed without recording
  snapshot changes. Logs are in `.build/ci/`.
- AddressSanitizer and ThreadSanitizer: the 15 tests selected by
  `(EventSubscriber|SubscribeTests|EventSignalDispatchTests)` passed under each sanitizer, with no
  findings. Builds used `.build/signals-asan` and `.build/signals-tsan`; logs are
  `/private/tmp/yabai-signals-asan.log` and `/private/tmp/yabai-signals-tsan.log`.
- All changed Swift files passed stock formatting and strict lint; `git diff --check` passed.

Compilation was warning-free. No live deployment or daemon restart was performed.
