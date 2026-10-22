# Phase 7: Daemon model cleanup

**Goal:**

- tree mutations report errors instead of trapping;
- no raw-pointer or sentinel state;
- the `Window` model separates observed AX data from user state;
- service install has typed errors and tested builders;
- the tab bar has one code path per operation.

**Prerequisites:** phase 4. **Phase gate:** `make ci`, plus `swift test --sanitize=thread` and `--sanitize=address`.

The test-only `Headless` seam (`Sources/Yabai/Headless.swift`, about 10 checks in 7 files) is deliberate and documented
in `doc/live-testing.md`; it is **not** part of this phase.

| ID | Title | Depends on |
|---|---|---|
| P7.1 | No force unwraps in tree mutation | — |
| P7.2 | No raw-pointer or sentinel state | — |
| P7.3 | Split the `Window` model | P7.2 |
| P7.4 | Typed service errors and tested builders | — |
| P7.5 | One tab bar code path per operation | — |

---

## P7.1 No force unwraps in tree mutation

**Where:**

- `Sources/Yabai/Con.swift` has about 39 force unwraps, for example `index!`, `focusIndex!` and `parent!` in the
  insert, remove, move and swap paths, plus `weak var raised: Con!`.
- List them with `grep -n '!' Sources/Yabai/Con.swift | grep -v '!=' | grep -v '//'`.

**Steps**

1. Classify every unwrap in the notes:
   - (a) guaranteed by a check a few lines above: rewrite with `guard let` in the same place;
   - (b) an invariant of the tree: replace with `guard … else { Logger.tree.fault("…"); return <safe value> }`, where a
     safe no-op exists;
   - (c) on a path reached from a command: make the function `throws(CommandError)`, and let the command report
     `CommandError("…\n")`.
2. `raised: Con!` becomes `Con?`. Fix the readers.
3. Don't change behavior for valid trees. The golden replay, `TreeTests`, `TreePropertyTests` (run ten times),
   `ViewInsertionTests` and `WindowCommandTests` must pass unchanged.
4. Add tests for two category (c) cases: a command against a malformed or absent container returns the error instead
   of crashing.

**Acceptance:** fewer than 5 force unwraps remain in `Con.swift`, each with a comment saying why it is safe.

**Gate:** quick. **Commit:** `P7.1 Replace tree force unwraps with guards and command errors`.

---

## P7.2 No raw-pointer or sentinel state

**Where:**

- `Process.swift`: `Atomic<UnsafeMutableRawPointer?>` holds an `NSRunningApplication` retained with `passRetained`,
  and `Workspace.swift` (around the running-application helpers) retains and releases it by hand.
- Sentinels:
  - `?? 0` pids in `Workspace.swift`;
  - connection id `0` in `Application.swift` and `WindowManager+Discovery.swift`;
  - `?? -1` in `SpaceID.swift`;
  - arrangement `0` in `DisplayID.swift`;
  - `UnsafeMutableRawPointer(bitPattern: 1/0)` as a comparator flag in `DisplayManager.swift`. If P5.3 already
    replaced it, skip that one.

**Steps**

1. Replace the atomic raw pointer with `let runningApplication = Mutex<NSRunningApplication?>(nil)` (Synchronization).
   - `NSRunningApplication` is not `Sendable`. Wrap it in a small `final class RunningApplicationBox: @unchecked
     Sendable`, with a `// NOTE:` explaining that AppKit allows reading its properties from any thread. Verify that
     claim in Apple's docs or the header comments. If it doesn't hold, confine access to `@MainActor` instead.
   - Remove the manual `passRetained` and `release` pairs.
2. Replace each sentinel with an Optional, and adapt callers. Read each caller: some compare with 0 to mean "unknown".
3. Run the sanitizers. This touches threads and object lifetimes.

**Acceptance:**

- `grep -rn "passRetained\|takeRetainedValue" Sources/Yabai/Process.swift Sources/Yabai/Workspace.swift` is empty.
- The listed sentinels are gone.
- TSan and ASan pass.

**Live check:** launch and quit apps, including one that is slow to launch (Xcode) and one that quits immediately. Hide
and unhide them; cmd-tab between them. No crash, and windows of new apps tile.

**Gate:** quick + sanitizers. **Commit:** `P7.2 Hold running applications and optional ids without raw pointers or sentinels`.

---

## P7.3 Split the `Window` model

**Where:** `Window.swift` declares 25+ Bools.

- An `Atomic` `valid` sits next to `isDestroyed`.
- `role`, `subrole` and `title` are `CFString`.
- `cachedTitle` converts on every read.
- `application` and `ref` are IUOs (`!`), and `Application.swift` has IUOs too.

**Steps**

1. Group the AX-observed facts (role, subrole, title, the minimized/fullscreen flags read from AX, resizable/movable)
   into `struct WindowAXState`, refreshed by one `refreshAXState()`. Store `String`, converted once at refresh time.
2. User and manager state stays on `Window` as it is: floating, sticky, scratchpad, layer, opacity, rule flags.
3. Remove the IUOs where the value is set in `init`. Where it is set later, make it Optional and handle nil at the
   readers. Record each choice.
4. Merge `valid` and `isDestroyed` only if their semantics are the same: `valid` is the cross-thread
   invalidate-once flag (P4.4). If they differ, document both in `///` comments.
5. Keep JSON query output byte-identical: the golden replay and `SerializeTests` must pass unchanged.

**Acceptance:** no `CFString` stored properties on `Window`, fewer IUOs (list the remaining ones), and the tests pass
unchanged.

**Live check:** `yabai -m query --windows` output matches a capture taken before the deploy (diff, ignoring frames), and
rules matching on title/role still apply to new windows.

**Gate:** quick. **Commit:** `P7.3 Separate observed AX state from window manager state`.

---

## P7.4 Typed service errors and tested builders

**Where:** `Sources/Yabai/Service.swift`:

- it returns `Int32` status codes and calls `Logger.daemon.fatal(...)` mid-function (home directory, `USER`, `PATH`,
  executable path, plist already installed / not installed);
- it builds the launchd plist and the `launchctl` arguments inline;
- the `USER` lookup is repeated in `Yabai.swift`, `Service.swift`, `ScriptingAddition.swift` and `IPC/Client.swift`,
  with different failure handling.

**Steps**

1. Add `enum ServiceError: Error { case missingEnvironment(String), alreadyInstalled(path:), notInstalled(path:), … }`.
   The public entry points (`install`, `uninstall`, `start`, `stop`, `restart`) catch it once, print the same message
   text as today, and return the same exit code. CLI output must stay identical; compare by reading.
2. Extract pure builders:
   - `static func plist(executable:path:user:) -> String` (or `Data`);
   - `static func launchctlArguments(for action:, uid:, plistPath:) -> [[String]]`.
3. Test both builders in `YabaiTests`: a golden string for the plist, and argument arrays for each action.
4. Add one `static func currentUser() -> String?` in a shared place, and use it at the four `USER` sites. Each site
   keeps its own failure policy, but through the shared lookup.

**Acceptance:** the builders are tested, `fatal(` no longer appears in `Service.swift` outside the entry points, and
`make install` passes.

**Live check:** the user runs `yabai --stop-service && yabai --start-service` and `yabai --restart-service`. Optionally,
in a test account, uninstall and install the service.

**Gate:** quick + release. **Commit:** `P7.4 Give service management typed errors and tested plist builders`.

---

## P7.5 One tab bar code path per operation

**Where:** `Sources/Yabai/TabBar.swift` branches between the classic SLS bar and the glass panel (`TabBarGlass.swift`)
at about 5 sites: render, order, hide, hit publishing, destroy. Color, tint and separator helpers are partly duplicated
between the two files.

**Steps**

1. Introduce `enum TabBarBackend { case classic(ClassicTabBar), glass(TabBarGlass) }`, with `ClassicTabBar` a `final
   class` holding the SLS window state that `TabBar` holds today. The conventions forbid protocols for this, so use the
   enum.
2. Give the enum one method per operation (`render`, `order`, `hide`, `destroy`, `hitFrame`), each a single `switch`.
   `TabBar` keeps the shared model (entries, frame, hits) and calls `backend.<op>`.
3. Move the shared color, tint and separator helpers into one place, used by both backends.
4. The z-order of nested cards is fragile (AGENTS.md: check screenshots as well as clicks). Keep the call order of
   SLS operations identical per backend, and list it in the commit body.
5. Tests: `TabBarTests` (including the image snapshot) pass unchanged. Add a test that switching `tab_bar_style` at
   runtime swaps the backend and destroys the old one, using headless recording.

**Acceptance:** `TabBar.swift` has no remaining `if glass`/`glass != nil` branches outside the backend switch, and the
tests pass.

**Live check:**
- nested tabbed containers in both `tab_bar_style glass` and `i3`;
- switch styles at runtime;
- click tabs, including nested ones;
- take screenshots and compare z-order with a screenshot from before the deploy.

**Gate:** quick + sanitizers. **Commit:** `P7.5 Route tab bar operations through one backend switch`.
