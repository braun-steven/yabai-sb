# Repository Guidelines

## Agent instructions

Read the Swift conventions below before writing or reviewing Swift, C/Swift bridges, `Package.swift` or `CPrivate` changes, and keep new pitfalls there.

The daemon is being refactored into idiomatic Swift: `doc/swift-refactor.md` holds the phased plan, its status board and the session reports. Before working on it, read its **How to use this file** (a phase runs as one subagent per subphase), **Rules** and **Target conventions**; code a phase touches follows the Target conventions, even where older code nearby does not. Its progress is tracked in the Claude Code Task list as its **Progress tracking** section describes: the phase agent keeps the list, and subphase agents report to it with `SendMessage`, since subagents do not get the Task tools.

For Codex: translate Claude's `Edit` tool to `apply_patch`, and `Bash` to the shell execution tool: use patch-based edits rather than shell scripts to change source files. The named `output-summarizer` is a role for a subagent that runs long-output commands and returns concise results; no definition for it exists in this checkout. When delegation is available, give it the exact command, working directory, question and desired result format. Otherwise capture logs and inspect the relevant failures and warnings. Run state-changing commands yourself.

yabai is a tiling window manager for macOS 27 on arm64, written in Swift 6. It talks to private macOS frameworks (SkyLight, etc.) through CPrivate. The scripting addition injected into Dock uses a Swift core with an Objective-C native adapter and loader (manual retain/release).

This is a personal fork. Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same commit. Only features go there: fixes to features of this fork do not get an entry.

## Project Structure
- `Package.swift`: complete SwiftPM build, with `OSAXEmbed` generating embedded C sources. The makefile wraps SwiftPM and publishes to `bin/yabai`.
- `Sources/Yabai/`: daemon and CLI. `main.swift` runs the client for `-m`, otherwise calls `Daemon.run` in `Yabai.swift`. `Service.swift` handles launchd; `Helpers.swift` contains shared helpers.
- `Sources/Yabai/IPC/`: client, daemon socket and domain handlers (`Message*.swift`), plus ordered query JSON in `Serialize.swift`.
- `Sources/Yabai/Platform/`: private SkyLight, AX and CoreDock wrappers, plus runtime symbol lookup in `MachO.swift`.
- `Sources/YabaiCore/`: pure logic without window server access: geometry, labels, space-layout math, ordered JSON, message tokens, values, selectors and rule/signal parsing.
- `Sources/CPrivate/`: C/ObjC target with private framework declarations, runtime-resolved function pointers, wrappers for APIs unavailable to Swift and MRR notifications in `Notify.m`.
- `osax/`: Swift scripting-addition core, native adapter and bootstrap/loader. `Plugins/OSAXEmbed/` invokes `scripts/build-osax.sh` to build arm64e binaries and generate `payload_bin.c` / `loader_bin.c` in its work directory; the SwiftPM `OSAX` target embeds those arrays. Its standalone package tests the core with recording/Mach mocks, outside Dock. Shared native socket helpers live in `core/IO.h`.
- `tests/YabaiCoreTests/` and `tests/YabaiTests/`: Swift Testing; the latter uses `@testable import Yabai` and holds the golden IPC snapshot in `Golden/`. Use `tests/`, not `Tests/`, on the case-insensitive filesystem.
- `doc/`: Asciidoc, generated manpage, refactor plan, payload and live-testing notes.
- `examples/`, `assets/`: sample configuration, icons, banner and plist.
- `scripts/`: signing, installation, payload history and the live harness in `scripts/live-tests/`.

## Build, Test, and Development Commands
- `make`: incremental debug arm64 build in `.build/`, copied atomically to `bin/yabai` after success. Every variant publishes to that path; failures preserve the previous binary.
- `make install`: standard SwiftPM release optimization; CPrivate defines `NDEBUG`. Both manifests treat Swift and C warnings as errors in all configurations.
- `make asan` / `make tsan`: Address/Thread sanitizer build, also enabling UBSan for C.
- `swift build` / `swift test`: complete build/test directly, including embedded OSAX sources; no preparation needed.
- `make clean`: removes `bin/`, `.build/`, `osax/.build/` and legacy generated `osax/*_bin.c`. Plugin input dependencies regenerate arrays automatically after native source/header/module-map/script changes.
- `make prepare`: optional `swift build --target OSAX`; ordinary SwiftPM/IDE use needs no separate step. See `doc/building.md`.
- `make test`: wraps `swift test`. A single test runs with `swift test --filter <name>`.
- `make check-build`: checks clean/no-op/native-input/toolchain-selection builds and Swift tests in a temporary source copy. Failures retain per-step logs; the checkout's caches and binary stay untouched.
- `make osax-test` / `make osax-payload`: isolated Swift Testing for the payload core / standalone arm64e dylib. Swift 2.1.36 is the only implementation; no core-selection option remains. See `doc/osax-prototypes.md` before any live reload.
- `swift test --filter Golden`: byte-for-byte replay of `tests/YabaiTests/Golden/commands.txt`, a regression snapshot of the IPC responses. Only after an intended response change, re-record with `GOLDEN_RECORD=1 swift test --filter Golden` and review every changed record.
- `make man`: regenerates `doc/yabai.1` from `doc/yabai.asciidoc` using asciidoctor. Edit the Asciidoc source.
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding to preserve Accessibility permission.
- `update-yabai-fork` (outside the repo, in `~/.local/bin`): release build, signing, install, sudoers update and restart. Commit first; the user runs this in a real terminal for sudo. Agents use `bash scripts/live-tests/deploy.sh install` instead; read `doc/live-testing.md` first.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: inspect payload updates across both the old and current paths.

There is no linter or `make analyze` target. Keep builds warning-free. CPrivate's warnings are configured in `Package.swift`; the separately built payload/loader use `scripts/build-osax.sh`. Sanitizer daemon builds use separate `.build/asan` and `.build/tsan` scratch directories; they do not instrument the embedded payload.

## Coding Style & Naming
- Swift 6, Swift Testing, four-space indentation, and the surrounding file's brace style. Names, file layout, models and errors follow the Target conventions in `doc/swift-refactor.md` (Swift API Design Guidelines, methods on the type they act on, code ordered by responsibility).
- Prefer final classes for reference models and structs/arrays for values. Keep `YabaiCore` independent of CPrivate and window server access.
- Remaining C/ObjC is C11 + manual retain/release (`-fno-objc-arc`) in CPrivate and OSAX. Add wrappers to CPrivate only when Swift cannot call the underlying API.

Model pitfalls:
- Enum tags can collide with functions (`ConOrientation` versus `con_orientation`); a property named like a lowercase type needs a module qualifier. Swift raw-value initializers use `rawValue:` explicitly.
- Enums with a `none` case (`ConZoom`, `TreeResult`, `MouseAction`): on an Optional of such an enum `.none` means `nil`, so keep them non-optional or spell `ConZoom.none`. Config values named `default` need backticks in the declaration (`ViewType`).
- Former pointer fields may remain IUOs to preserve nil behavior. Files must import `AppKit` / `CPrivate` explicitly; nothing re-exports them.
- Type byte fixtures as `[UInt8]` when mixing typed bytes and integer literals; inferred `[Any]` gives raw-pointer APIs the wrong storage (`WindowAnimationTests.swift`).

## Testing Guidelines
- Swift Testing with descriptive test names; add tests with `@Test` and `#expect`. Older tests still carry their C `TEST_FUNC` names as display names (`@Test("label_list")`); renaming them is fine.
- Tests changing global managers belong in the serialized `DaemonState` suite. They must avoid window server side effects. Golden replay leaves config behind; explicitly restore defaults a test depends on.
- Before live tests, deployments, sanitizer runs or crash analysis, read `doc/live-testing.md`. Deploys restart yabai and reset all layouts; tell the user beforehand and restore the installed binary afterward.
- Live helpers must translate getter values for restore (`focus_follows_mouse`: `disabled` → `off`), tolerate already-focused spaces, and find tabbed containers recursively rather than assuming a tabbed workspace root.
- Recheck connected displays before live tests: a saved two-display setup can become laptop-only. Use current geometry, restore the actually visible spaces, and explicitly skip cross-display checks when unavailable.
- Synthetic mouse helpers must preflight event-posting access and propagate failures. A command sandbox can deny posting even with Accessibility granted; `CGEvent.post` then silently drops moves and drags (`scripts/live-tests/mouse.swift`).
- Performance comparisons must hold autotiling off throughout reinsertion workloads and verify the initial tree. Reject runs spanning a desktop lock and match window ids across builds. Visible border probes must reject occluded pixels; ScreenCaptureKit display timestamps measure composited frames, not physical light output. See `scripts/live-tests/perf.py` and `border_perf.swift`.

## Architecture

**Targets and startup.** SwiftPM builds the executable `Yabai`, pure library `YabaiCore`, and C targets `CPrivate` and `OSAX`. `Yabai.swift` holds the startup sequence and `Service.swift` the launchd commands. Enums live with the type or manager that uses them (`ConLayout` in `Con.swift`, `FocusFollowsMouse` in `WindowManager.swift`), shared math and string helpers in `Helpers.swift`. Config values are parsed and printed through their String raw values (`parseConfigChoice`). CPrivate wrappers preserve unavailable or deprecated calls and ObjC exception handling. Private +1 CF functions need `CF_RETURNS_RETAINED` even when their names lack Copy/Create.

**Models and managers.** `WindowManager`, `SpaceManager`, `DisplayManager`, `ProcessManager` and `MouseState` own Swift state. Their globals/accessors live with the managers. `Window`, `Application`, `Process`, `View`, `Con` and `TabBar` are reference models with identity equality and ARC lifetimes. Managers keep models in Dictionaries and Sets; loops whose order a user can observe sort explicitly (windows by id, processes by pid, views by space id). Labels use `LabelList`, lists use arrays.

**Window, space and process logic.** `WindowManager*.swift` covers discovery, lookup, focus, rules, scratchpads and tree commands. `Display*.swift`, `Space*.swift` and `View.swift` manage displays, spaces and layouts; `SpaceManager+SpaceLayout.swift` reconciles configured space counts. `ProcessManager.swift` receives Carbon application events; `Workspace.swift` observes NSWorkspace and NSRunningApplication. `Window.swift` and `Application.swift` wrap individual AX/SkyLight objects and AX notifications.

**Tree layout.** Each `View` owns a container tree. `Con` has a weak parent and ordered children/focus arrays; `Con.swift` implements the i3 operations. `TreeView.swift` applies frames, tab bars and stacking; `WindowManager+Tree.swift` implements navigation and cross-display moves. `ViewArea` in YabaiCore handles pure geometry.

**Event loop and isolation.** `EventLoop.swift` serializes handlers on the `yabai.wm` dispatch executor of `@WM`. Producers post an `Event` with associated values from AX, Carbon, SkyLight, NSWorkspace/KVO, the mouse event tap and the IPC thread. Never use `Task {}` for events: it can reorder them. Handlers in `EventHandlers*.swift` run synchronously, then flush signals. To add an event, add its enum case, dispatch case and handler. `MissionControl.swift` owns the Dock observer and connection callback. Cross-thread flags use Swift Atomics. The process table keeps the main-thread Carbon/event-loop access pattern; do not assume the model is compiler-enforced actor isolation yet (phase 4).

**IPC / CLI.** `Client.swift` sends argument bytes over `/tmp/yabai_$USER.socket`. `MessageLoop.swift` accepts connections and posts daemon-message events. Handlers parse `Message`, write `Response`, throw `CommandError.fail` and call Swift managers. YabaiCore holds parsers, selectors, labels and rule/signal logic; `CSelectorContext` in `IPC/SelectorContext.swift` connects selectors to models. `Serialize.swift`, YabaiCore's `WindowInfo` and `Rule.swift` write ordered JSON. New commands need handler parsing, `doc/yabai.asciidoc` documentation (`make man`), and usually a CHANGELOG entry.

**Rules and signals.** `Rule.swift` matches rules and serializes `rule --list`; `WindowManager+Rules.swift` applies effects. YabaiCore's `EventSignal.swift` holds signal filters and JSON; the executable's `EventSignal.swift` queues and flushes commands with `posix_spawn` through `env`. Config scripts also use `posix_spawn`; Swift must never execute in a forked child.

**Rendering and input.** `Border.swift` owns four edge windows per border under a Mutex; SkyLight callbacks move them without reading the tree. `TabBar.swift` draws classic bars and publishes immutable hit-test snapshots under a Mutex. `TabBarGlass.swift` snapshots on the event loop and renders with AppKit on the main queue. `WindowAnimation.swift` retains AX references and copied app names for concurrent frame workers, stores window ids for animations, and protects proxy/takeover state with a Mutex. `MouseHandler.swift` owns the event tap and drag/drop decisions. Main-queue blocks retain their render owners until the last pending block completes.

**Scripting addition.** `osax/loader.m` uses `bootstrap.S` to inject the native adapter and Swift core into Dock. `payload.m` owns private operations; `core/swift` owns validated framing, replies and fade state. Requests on `/tmp/yabai-sa_$USER.socket` retain their length-prefixed encoding; an optional status byte distinguishes rejection from legacy EOF/unconfirmed. The daemon uses `SAConnection.swift` with absolute deadlines. macOS 27 patterns/offsets remain in `arm64_payload.m`. Bump `OSAX_VERSION` for behavior/protocol changes; see `doc/payload-updates.md` and `doc/osax-prototypes.md`.

**Platform gating.** The supported target is macOS 27 on arm64; the injected payload is arm64e. `verify_os_version` in `osax/payload.m` accepts macOS 27 only. Add version branches only when a newer release needs different behavior.

## Commit & Pull Request Guidelines
- Commit directly to `main`; no feature branches needed, unless the user asks for a separate branch (e.g. for experimental work).
- Commits commonly use concise, imperative subjects, often prefixed with an issue/PR id (e.g. `#1234 fix …`) or a version tag (e.g. `v7.1.16`).
- PRs should include: macOS version + arch, repro steps, expected vs actual behavior, and any relevant logs/output (e.g. `bin/yabai --version`, `--verbose` when appropriate).

## Swift conventions and pitfalls

Keep entries brief and point to an example. When something costs real time, add it here in the same commit.

### Toolchain

Swift 6.4 on macOS 27 is near the edge of the model's training data. For recent features (SwiftPM concurrency defaults, `isolated deinit`, `Mutex`/`Atomic`, custom executors), trust `swift --version`, compiler diagnostics and SDK interfaces over memory. When unsure, try a scratch file first.

### Conventions

- **Target shape:** see Target conventions in `doc/swift-refactor.md`.
- **Performance:** prefer `final class` and structs on hot paths (mouse drag, animations, tree updates). Avoid existentials (`any P`) and closures capturing state in loops there.
- **Isolation:** `@MainActor` only for AppKit; window manager state is `@WM`. Plain value types are `Sendable` without annotations.
- **Errors:** command handlers `throw CommandError.fail(...)`. Platform wrappers return optionals or `Bool`; do not invent AX/SkyLight error types.

### Build and toolchain pitfalls

- **Plugin-generated C:** SwiftPM requires `// swift-tools-version: 6.4;(experimentalCGen)` in the root manifest. Without the experimental opt-in it warns and omits generated C. Preserve the suffix when updating the tools version; `OSAXEmbed` must declare every native input.
- **Native toolchain selection:** `SWIFT`/`SWIFT_FLAGS` select only outer SwiftPM behavior. `osax-toolchain.sh` resolves native tools/SDK through `xcrun` with `DEVELOPER_DIR`, `TOOLCHAINS`, and `SDKROOT`; both the per-build identity header and native commands use it. Toolchain identity changes invalidate native generation automatically.
- **Swift dylib output paths:** the default install name contains the output path. `build-osax.sh` sets the historical `.build/osax/swift/payload` install name explicitly so arbitrary plugin work directories preserve the live-tested bytes.
- **Optimized Swift C exports:** an internal `@_cdecl` can become local during SwiftPM release prelinking, even when debug tests link. Mark cross-target exports `public` and build a release consumer (`osax/core/swift/Core.swift`).
- **`@_cdecl` functions** accept only C-representable types (raw/typed C pointers, integers, `Bool`), and CF objects they return are autoreleased (+0) regardless of the C prototype (`osax/core/swift`).
- **Payload tests:** daemon ASan/TSan do not instrument the separately compiled payload. Use the standalone `osax` package; test signal interruptions on a disposable pthread with its signal explicitly unblocked, because Swift Testing/sanitizers can inherit a blocked mask.
- **Dock signatures and ownership:** pattern matches are candidates, not identities (Spaces and HotCorners both match `dock_spaces` on 26A434). Validate decoded targets and record Dock hash/UUID. Resolve private-call ownership from the callee and Dock's callers before changing retain/release (`doc/osax-prototypes.md`).
- **Swift Build prelinks C targets** with `ld -r` into one object, making hidden symbols local. Do not use `-fvisibility=hidden` on CPrivate: Swift then cannot link its functions.
- **A C target without sources** does not link: Swift Build expects `<Target>.o`. `CPrivate.c` holds the runtime-resolved function pointers.
- **Swift Build adds Xcode's default warnings** (e.g. `-Wshorten-64-to-32`). `Package.swift` disables them to keep the original warning set. After a toolchain update, disable new defaults there unless they reveal real bugs.
- **SDK version of the binary:** Swift Build's `--sysroot` does not tell clang the SDK version, so the binary can claim the deployment target as its SDK and AppKit treats it as old. `Package.swift` passes `-isysroot $SDKROOT` (set by xcrun's Swift shim and the makefile). `vtool -show-build bin/yabai | grep sdk` must show the SDK, e.g. 27.0.
- **Inline header functions reading `NDR_record`** (or other non-static header bodies) link in debug but produce a release duplicate symbol: Swift's copy brings its own definition. Move bodies to `Sources/CPrivate/CPrivate.c`, with header declarations (`SLSGetWindowSubLevelBounded`). Run `make install` after CPrivate changes.
- **All type errors at once:** `swift build` (even with `-continue-building-after-errors`) stops after the first failing compile batch. For a mass edit, build YabaiCore, then run `xcrun swiftc -typecheck -wmo -continue-building-after-errors -swift-version 6 -target arm64-apple-macos27.0 -I .build/out/Products/Debug -Xcc -fmodule-map-file=Sources/CPrivate/include/module.modulemap -Xcc -ISources/CPrivate/include -Xcc -fmodule-map-file=.build/out/Intermediates.noindex/GeneratedModuleMaps/OSAX.modulemap -module-name Yabai $(find Sources/Yabai -name '*.swift')`.
- **Case-insensitive filesystem:** `Tests/` and `tests/` are the same. Swift tests use `tests/YabaiCoreTests` via `path:` in `Package.swift`.
- **Autolinking:** `import AppKit` autolinks many `libswift*` overlays. They are in the OS; do not trim them.

### C interop pitfalls

- **Swift imports C headers with ARC.** Manual retain/release bodies belong in `.m` files (`Notify.m`), with only declarations in `CPrivate.h`. The importer also makes structs with ObjC pointer fields ARC structs.
- **Nullability is per file:** after one annotation, clang requires all pointers annotated (`-Wnullability-completeness`), including macro expansions. `CONNECTION_CALLBACK` is unannotated; the `connection_callback` typedef carries qualifiers. Spell both levels of multi-level pointers inside `CF_ASSUME_NONNULL`, e.g. `CFTypeRef _Nullable *_Nonnull`.
- **Imported C types:** `Boolean` imports as `Bool`, `CGError` as an enum (`== .success`), CF out-parameters as `UnsafeMutablePointer<Unmanaged<T>?>` (use `takeRetainedValue()` for Copy/Create functions). See `Sources/Yabai/Platform/SkyLight.swift`.
- **C enums:** anonymous `enum { kX = 1 }` imports as `Int` without `.rawValue`; `CF_ENUM` types like `CGEventField` import as structs with failable `init(rawValue:)`.
- **Macros naming constants** do not import (`LAYER_BELOW kCGBackstopMenuLevelKey`), while literals (`LAYER_AUTO 0`) do. Use the imported constant (`CGWindowLevelKey.backstopMenu.rawValue`, `WindowLayer.level` in `WindowManager.swift`). **Macros composed from macros** do not import either: spell the value in Swift (`ApplicationNotifications.required` in `Application.swift` for `AX_APPLICATION_ALL`).
- **`&x` in `CVarArg...`** does not compile: inout-to-pointer conversion requires pointer parameters. Use `withUnsafeMutablePointer(to:)` or a buffer.
- **Fixed-size C arrays import as tuples:** use `withUnsafe(Mutable)Bytes(of:)`.
- **Swift honors `CF_CONSUMED`:** it retains before the call. Pass owned objects normally (`takeRetainedValue()` then the consuming call); do not add `retain()`.
- **APIs unavailable to Swift** (`CGPostMouseEvent`, `CGEventCreate`, `CGEventPost`, `CGEventSetIntegerValueField`) can be called through inline CPrivate wrappers with deprecated warnings suppressed. Clang ignores Swift-only unavailability. Prefer Swift event methods where available (`CGEvent(source:)`, `post(tap:)`, `setIntegerValueField(_:value:)`).
- **APIs deprecated in macOS 10.9 or earlier** are unavailable to Swift, including Process Manager (`GetProcessPID`, `GetNextProcess`, `CopyProcessName`, `IsProcessVisible`, `SameProcess`). Use `Process*C` wrappers in `CPrivate.h`. Carbon Events (`InstallEventHandler`, `GetEventParameter`) work directly (`ProcessManager.swift`).
- **Swift cannot catch NSException:** unwinding through Swift terminates the process. Keep ObjC `@try/@catch` in an inline wrapper under `#ifdef __OBJC__` in `CPrivate.h` (`NSObjectRemoveObserverC`, used by `Workspace.swift`).
- **`fork()`, `environ`, `_NSGetEnviron` are unavailable in Swift.** Use `posix_spawn` with `environ_global()` from `CPrivate.h` (`EventSignals.spawn`). Never run Swift in a forked child: only async-signal-safe code is safe before exec.
- **C function-pointer variables** are rejected as Swift 6 globals: access them through a CPrivate accessor (`SLSHasBridgedWindowOperation`).
- **`sel_registerName` returns `Selector`:** use `unsafeBitCast(sel, to: UnsafeMutableRawPointer.self)` for objc_msgSend casts (`SLS.bridgedMoveWindows`).
- **C callbacks** such as `CFComparatorFunction` get optional pointers; unwrap before `Unmanaged<T>.fromOpaque`.

### Swift pitfalls

- **`String ==` is not `strcmp`:** Swift compares canonical equivalence (precomposed é equals e + U+0301). For byte comparisons, use `a.utf8.elementsEqual(b.utf8)` (`LabelList` in `Sources/YabaiCore/Label.swift`).
- **Global CF `let`s** (`let x = "AXFullScreen" as CFString`) are not concurrency-safe in Swift 6. Keep a `String` and bridge at the call (`axFullscreenAttribute` in `Window.swift`).
- **Names matching types** (`rule`, `token`) shadow the type in parameters and locals: `let rule = …assumingMemoryBound(to: rule.self)` fails as use before declaration. Use `result`, `first`, `target`, etc.
- **Custom global actors lack static `assumeIsolated`.** `WM.shared.assumeIsolated` cannot call `@WM` functions. `WM.assumeIsolated` (`EventLoop.swift`) uses `preconditionIsolated` and `unsafeBitCast`, like MainActor, and traps off `yabai.wm`. Its closure cannot capture non-Sendable raw pointers: use `Handoff`. Test actor code with `@Test @WM func` (`goldenReplay`).
- **Typed ids** (`WindowID`, `SpaceID`, `DisplayID` in `Sources/YabaiCore/Identifiers.swift`): `.map(WindowID.init)` is ambiguous between `init(_:)` and `init(rawValue:)`; write `.map { WindowID($0) }`. C out-parameters (`&wid` for `SLSNewWindow`, `_AXUIElementGetWindow`) need a raw `UInt32` local, wrapped afterwards (`AXUIElement.windowID`). The SA payload packs ids through `SAPayload.pack(_: WindowID)`, which writes the raw value. No id is an Optional, never 0: the ids are not integer literals outside tests (`tests/*/IdentifierLiterals.swift`), raw window server values enter through `WindowID(nonzero:)`, and printed output keeps 0 with `x?.rawValue ?? 0` (`Serialize.swift`).
- **Atomics:** `Synchronization.Atomic` owns its storage; Swift-owned flags use global `let Atomic` values (`pendingWindowFocus`). Where code mirrors C `__atomic_sub_fetch`, use `wrappingSubtract`/`wrappingAdd`, not trapping `subtract`/`add`.
- **`#expect` cannot capture non-copyable values** such as `Atomic`: save the operation's result to a `let` first (`mouse_event_coalescing` in `EventHandlerTests.swift`).
- **Main-queue blocks using Swift objects** must capture them strongly; the final pending block releases on the main queue (`TabBarGlass.swift`).
- **Executable tests:** `YabaiTests` depends on executable `Yabai` and uses `@testable import Yabai`. Swift Testing runs in parallel: tests changing global managers must use `@Suite(.serialized)` (`MessageConfigTests.swift`) and avoid window-server calls.
- **Golden replay leaves config behind** on global managers in `DaemonState` (e.g. `tree_workspace_layout tabbed`). Later tests must set defaults explicitly; suite `init()` runs per test (`TreeTests`).

### Window server behavior

- **No focused window:** some focus commands run without a focused window. Lookups such as `window_manager_find_tree_view(wm, nil)` return nil and callers fail cleanly (`window_manager_tree_focus_*`, `window_manager_set_window_layout`, `window_manager_tree_split`); keep those parameters optional.
- **Hide-single in split tabs:** count the visible leaves of the active tab, independently of auto-padding's container count. Switching between single-window and split tabs must refresh all space borders so every affected window updates (`treeVisibleWindowCount`, `Border.refreshSpace(of:)`).
- **Subscribe before initial tiling:** AX frame setters can return before WindowServer publishes the final frame. Register SkyLight notifications for new windows before tiling (`windowCreated`, `applicationLaunched`); otherwise the border can retain its creation frame until another move. Check intermediate window counts with `scripts/live-tests/border_geometry.swift`, since the next relayout can hide the bug.
- **Card ordering in split tabs:** the card is ordered right below the focused window on the main queue, after `tree_raise_tabs`, and applications raise their focused window above its split siblings. Re-order the rest of the active tab above the focused window after every card order (`tabCardOrdered`, `tree_card_did_order`); the tab-order cache otherwise skips it. Check the real stack with `CGWindowListCopyWindowInfo` after focusing the window from another application.
- **Nested glass panels:** keep AppKit ordering synchronized with SkyLight even for visible panels, and order/redraw cards outermost first. Creation order changes during layout/style rebuilds; otherwise an outer backdrop can hide an inner tab strip while its click tests still pass (`TabBarGlass.swift`, `TabBar.outerFirst`). Verify screenshots as well as clicks.
- **Glass pointer feedback:** nonactivating panels ignore mouse events to preserve application focus. The tap must receive mouse moves even with focus-follows-mouse off, while an atomic flag gates focus events. Draw feedback in its own view because NSButton can replace its backing-layer background during drawing (`MouseHandler.swift`, `TabBarGlass.swift`).
