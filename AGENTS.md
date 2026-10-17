# Repository Guidelines

## Codex instructions

This file combines the repository guidelines with the Swift conventions from `.claude/skills/swift-port-conventions/SKILL.md`. Read the Swift conventions below before writing or reviewing Swift, C/Swift bridges, `Package.swift` or `CPrivate` changes. Keep new pitfalls here; when working on the Swift port, also note them in the Handoff log of `doc/swift-port.md`.

In `doc/swift-port.md`, references to the Claude Swift conventions skill mean the section below for Codex. Translate Claude's `Edit` tool to `apply_patch`, and `Bash` to the shell execution tool: use patch-based edits rather than shell scripts to change source files. The named `output-summarizer` is a role for a subagent that runs long-output commands and returns concise results; no definition for it exists in this checkout. When delegation is available, give it the exact command, working directory, question and desired result format. Otherwise capture logs and inspect the relevant failures and warnings. Run state-changing commands yourself.

For Swift-port work, the branch and commit rules in `doc/swift-port.md` take precedence over the general master-branch guidance below: stay on `swift-port`, preserve behavior one-to-one, and merge into `master` only when the user asks after P14.

yabai is a tiling window manager for macOS 27 on arm64, written in Swift 6. It talks to private macOS frameworks (SkyLight, etc.) through CPrivate. The scripting addition injected into Dock remains Objective-C with manual retain/release. On branch `swift-port`, read `doc/swift-port.md` before working.

This is a personal fork. Whenever a new feature is added, update the "Fork changes" list at the top of `README.md` in the same commit. Only features go there: fixes to features of this fork do not get an entry.

## Project Structure
- `Package.swift`: SwiftPM package; the thin makefile builds the embedded payload first and drives SwiftPM.
- `Sources/Yabai/`: daemon and CLI. `main.swift` runs the client for `-m`, otherwise calls `yabai_main` in `Yabai.swift`. `Service.swift` handles launchd; `Definitions.swift` preserves model constants and value types; `Helpers.swift` contains shared helpers.
- `Sources/Yabai/IPC/`: client, daemon socket and domain handlers (`Message*.swift`), plus ordered query JSON in `Serialize.swift`.
- `Sources/Yabai/Platform/`: private SkyLight, AX and CoreDock wrappers, plus runtime symbol lookup in `MachO.swift`.
- `Sources/Yabai/Shims/`: Swift conversions for geometry, layouts, selectors and rules. These are ordinary Swift functions; no C entry points remain.
- `Sources/YabaiCore/`: pure logic without window server access: geometry, labels, space-layout math, ordered JSON, message tokens, values, selectors and rule/signal parsing.
- `Sources/CPrivate/`: C/ObjC target with private framework declarations, runtime-resolved function pointers, wrappers for APIs unavailable to Swift and MRR notifications in `Notify.m`.
- `osax/`: native scripting-addition adapter, bootstrap/loader and comparable ObjC/Swift cores. The makefile builds arm64e binaries and generates `payload_bin.c` / `loader_bin.c`; the SwiftPM `OSAX` target embeds those arrays. Its standalone package tests both cores with recording/Mach mocks, outside Dock.
- `tests/YabaiCoreTests/` and `tests/YabaiTests/`: Swift Testing; the latter uses `@testable import Yabai` and holds the golden IPC capture in `Golden/`. No C test harness remains. Use `tests/`, not `Tests/`, on the case-insensitive filesystem.
- `doc/`: Asciidoc, generated manpage, Swift-port plan, payload and live-testing notes.
- `examples/`, `assets/`: sample configuration, icons, banner and plist.
- `scripts/`: signing, installation, payload history and the live harness in `scripts/live-tests/`.

## Build, Test, and Development Commands
- `make`: incremental debug arm64 build in `.build/`, copied to `bin/yabai`. Every build variant replaces `bin/`.
- `make install`: optimized release build; Swift warnings are errors. CPrivate uses `-O3 -DNDEBUG`.
- `make asan` / `make tsan`: Address/Thread sanitizer build, also enabling UBSan for C.
- `make clean`: removes `bin/`, `.build/` and generated `osax/*_bin.c`. Payload/loader dependencies also regenerate the arrays when their sources change.
- `make test`: generates OSAX arrays if needed, then runs `swift test`. A single test runs with `swift test --filter <name>`.
- `make osax-test` / `make osax-prototypes`: isolated Swift Testing for the payload cores / both arm64e dylibs. `OSAX_CORE=swift make install` selects experimental 2.1.36; default ObjC is 2.1.35. See `doc/osax-prototypes.md` before any live reload.
- `swift test --filter Golden`: byte-for-byte replay of `tests/YabaiTests/Golden/commands.txt`. Only after an intended response change, re-record with `GOLDEN_RECORD=1 swift test --filter Golden` and review every changed record.
- `make man`: regenerates `doc/yabai.1` from `doc/yabai.asciidoc` using asciidoctor. Edit the Asciidoc source.
- `./scripts/codesign ./bin/yabai`: re-sign after rebuilding to preserve Accessibility permission.
- `update-yabai-fork` (outside the repo, in `~/.local/bin`): release build, signing, install, sudoers update and restart. Commit first; the user runs this in a real terminal for sudo. Agents use `bash scripts/live-tests/deploy.sh install` instead; read `doc/live-testing.md` first.
- `bash scripts/payload-history.sh [--grep <re>] [--show <rev>]`: inspect payload updates across both the old and current paths.

There is no linter or `make analyze` target. Keep builds warning-free. CPrivate's warnings are configured in `Package.swift`; the separately built payload/loader use the makefile's OSAX flags.

## Coding Style & Naming
- Swift 6, Swift Testing, four-space indentation, and the surrounding file's brace style. Ported functions retain their C order and names where that helps one-to-one comparison.
- Prefer final classes for reference models and structs/arrays for values. Keep `YabaiCore` independent of CPrivate and window server access.
- Remaining C/ObjC is C11 + manual retain/release (`-fno-objc-arc`) in CPrivate and OSAX. Add wrappers to CPrivate only when Swift cannot call the underlying API.

P14 model and bridge pitfalls:
- Enum tags can collide with functions (`ConOrientation` versus `con_orientation`); properties named like their types need a module qualifier (`Yabai.area()`). Swift raw-value initializers use `rawValue:` explicitly.
- Former pointer fields may remain IUOs to preserve nil behavior; Swift models have no `.pointee` shim. Removing `import YabaiC` also removes Cocoa/CPrivate re-exports; import `AppKit` / `CPrivate` explicitly.
- Type byte fixtures as `[UInt8]` when mixing typed bytes and integer literals; inferred `[Any]` gives raw-pointer APIs the wrong storage (`WindowAnimationTests.swift`).
- Bridge-era conventions referring to `src/`, YabaiC, model `@_cdecl` shims, temporary storage or the C harness are historical. Current wrappers are in CPrivate, notifications in `Notify.m`, and globals/models are Swift. The full migration history remains in `.claude/skills/swift-port-conventions/SKILL.md`.

## Testing Guidelines
- All 82 original C tests are ported to Swift Testing. Keep their C `TEST_FUNC` names as display names (`@Test("label_list")`); add new tests with `@Test` and `#expect`.
- Tests changing global managers belong in the serialized `DaemonState` suite. They must avoid window server side effects. Golden replay leaves config behind; explicitly restore defaults a test depends on.
- Before live tests, deployments, sanitizer runs or crash analysis, read `doc/live-testing.md`. Deploys restart yabai and reset all layouts; tell the user beforehand and restore the installed binary afterward.
- Live helpers must translate getter values for restore (`focus_follows_mouse`: `disabled` → `off`), tolerate already-focused spaces, and find tabbed containers recursively rather than assuming a tabbed workspace root.
- Recheck connected displays before live tests: a saved two-display setup can become laptop-only. Use current geometry, restore the actually visible spaces, and explicitly skip cross-display checks when unavailable.
- Synthetic mouse helpers must preflight event-posting access and propagate failures. A command sandbox can deny posting even with Accessibility granted; `CGEvent.post` then silently drops moves and drags (`scripts/live-tests/mouse.swift`).
- Performance comparisons must hold autotiling off throughout reinsertion workloads and verify the initial tree. Reject runs spanning a desktop lock and match window ids across builds. Visible border probes must reject occluded pixels; ScreenCaptureKit display timestamps measure composited frames, not physical light output. See `scripts/live-tests/perf.py` and `border_perf.swift`.

## Architecture

**Targets and startup.** SwiftPM builds the executable `Yabai`, pure library `YabaiCore`, and C targets `CPrivate` and `OSAX`. There is no unity build or YabaiC bridge. `Yabai.swift` preserves the original startup sequence and `Service.swift` the launchd commands. Constants and formerly shared small structs live in `Definitions.swift`, shared math and string helpers in `Helpers.swift`. CPrivate wrappers preserve unavailable or deprecated calls and ObjC exception handling. Private +1 CF functions need `CF_RETURNS_RETAINED` even when their names lack Copy/Create.

**Models and managers.** `WindowManager`, `SpaceManager`, `DisplayManager`, `ProcessManager` and `MouseState` own Swift state. Their globals/accessors live with the managers. `Window`, `Application`, `Process`, `View`, `Con` and `TabBar` are reference models with identity equality and ARC lifetimes. `Table.swift` preserves the old C hash-table bucket, insertion and rehash iteration order because query JSON depends on it; do not substitute a Dictionary. Labels use `LabelList`, lists use arrays. Rules remain Swift `rule` / `rule_effects` values behind explicit heap pointers.

**Window, space and process logic.** `WindowManager*.swift` covers discovery, lookup, focus, rules, scratchpads and tree commands. `Display*.swift`, `Space*.swift` and `View.swift` manage displays, spaces and layouts; `SpaceLayout.swift` reconciles configured space counts. `ProcessManager.swift` receives Carbon application events; `Workspace.swift` observes NSWorkspace and NSRunningApplication. `Window.swift` and `Application.swift` wrap individual AX/SkyLight objects and AX notifications.

**Tree layout.** Each `View` owns a container tree. `Con` has a weak parent and ordered children/focus arrays; `Tree.swift` implements the i3 operations one-to-one. `TreeView.swift` applies frames, tab bars and stacking; `WindowManagerTree.swift` implements navigation and cross-display moves. `ViewArea` in YabaiCore handles pure geometry.

**Event loop and isolation.** `EventLoop.swift` serializes handlers on the `yabai.wm` dispatch executor of `@WM`. Producers post an `Event` with associated values from AX, Carbon, SkyLight, NSWorkspace/KVO, the mouse event tap and the IPC thread. Never use `Task {}` for events: it can reorder them. Handlers in `EventHandlers*.swift` run synchronously, then flush signals. To add an event, add its enum case, dispatch case and handler. `MissionControl.swift` owns the Dock observer and connection callback. Cross-thread flags use Swift Atomics. The process table retains the original main-thread Carbon/event-loop access pattern; do not assume the whole legacy model is compiler-enforced actor isolation.

**IPC / CLI.** `Client.swift` sends argument bytes over `/tmp/yabai_$USER.socket`. `MessageLoop.swift` accepts connections and posts daemon-message events. Handlers parse `Message`, write `Response`, throw `CommandError.fail` and call Swift managers. YabaiCore holds parsers, selectors, labels and rule/signal logic; `CSelectorContext` in `Shims/MessageShims.swift` connects selectors to models. `Serialize.swift`, YabaiCore's `WindowInfo` and `Rule.swift` write ordered JSON. New commands need handler parsing, `doc/yabai.asciidoc` documentation (`make man`), and usually a CHANGELOG entry.

**Rules and signals.** `Rule.swift` matches rules and serializes `rule --list`; `WindowManagerRules.swift` applies effects. YabaiCore's `EventSignal.swift` holds signal filters and JSON; the executable's `EventSignal.swift` queues and flushes commands with `posix_spawn` through `env`. Config scripts also use `posix_spawn`; Swift must never execute in a forked child.

**Rendering and input.** `Border.swift` owns four edge windows per border under a Mutex; SkyLight callbacks move them without reading the tree. `TabBar.swift` draws classic bars and publishes immutable hit-test snapshots under a Mutex. `TabBarGlass.swift` snapshots on the event loop and renders with AppKit on the main queue. `WindowAnimation.swift` retains AX references and copied app names for concurrent frame workers, stores window ids for animations, and protects proxy/takeover state with a Mutex. `MouseHandler.swift` owns the event tap and drag/drop decisions. Main-queue blocks retain their render owners until the last pending block completes.

**Scripting addition.** `osax/loader.m` uses `bootstrap.S` to inject the native adapter and selected core into Dock. `payload.m` owns private operations; `core/objc` or experimental `core/swift` owns validated framing, replies and fade state. Requests on `/tmp/yabai-sa_$USER.socket` retain their length-prefixed encoding; an optional status byte distinguishes rejection from legacy EOF/unconfirmed. The daemon uses `SAConnection.swift` with absolute deadlines. macOS 27 patterns/offsets remain in `arm64_payload.m`. Bump each variant's `OSAX_VERSION` for behavior/protocol changes; see `doc/payload-updates.md` and `doc/osax-prototypes.md`.

**Platform gating.** The supported target is macOS 27 on arm64; the injected payload is arm64e. `verify_os_version` in `osax/payload.m` accepts macOS 27 only. Add version branches only when a newer release needs different behavior.

## Commit & Pull Request Guidelines
- Commit directly to `master`; no feature branches needed, unless the user asks for a separate branch (e.g. for experimental work).
- Commits commonly use concise, imperative subjects, often prefixed with an issue/PR id (e.g. `#1234 fix …`) or a version tag (e.g. `v7.1.16`).
- PRs should include: macOS version + arch, repro steps, expected vs actual behavior, and any relevant logs/output (e.g. `bin/yabai --version`, `--verbose` when appropriate).

## Swift conventions and pitfalls

Migrated from `.claude/skills/swift-port-conventions/SKILL.md`, with overlapping guidance condensed. Keep entries brief and point to an example. When something costs real time, add it here in the same commit and note it in the Handoff log of `doc/swift-port.md`.

### Toolchain

Swift 6.4 on macOS 27 is near the edge of the model's training data. For recent features (SwiftPM concurrency defaults, `isolated deinit`, `Mutex`/`Atomic`, custom executors), trust `swift --version`, compiler diagnostics and SDK interfaces over memory. When unsure, try a scratch file first.

### Conventions

- **Performance:** prefer `final class` and structs on hot paths (mouse drag, animations, tree updates). Avoid existentials (`any P`) and closures capturing state in loops there.
- **Isolation:** `@MainActor` only for AppKit; window manager state is `@WM`. Plain value types are `Sendable` without annotations.
- **Unit tests:** use Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`). Name a ported test after its C `TEST_FUNC`, so the ledger stays countable.
- **Errors:** command handlers `throw CommandError.fail(...)`. Platform wrappers return optionals or `Bool` as C did; do not invent AX/SkyLight error types.
- **Style:** keep the C file's function order in its Swift port so comparisons with the original remain readable.

### Pitfalls learned so far

- **Optimized Swift C exports:** an internal `@_cdecl` can become local during SwiftPM release prelinking, even when debug tests link. Mark cross-target exports `public` and build a release consumer (`osax/core/swift/Core.swift`).
- **Payload tests:** daemon ASan/TSan do not instrument the separately compiled payload. Use the standalone `osax` package; test signal interruptions on a disposable pthread with its signal explicitly unblocked, because Swift Testing/sanitizers can inherit a blocked mask.
- **Dock signatures and ownership:** pattern matches are candidates, not identities (Spaces and HotCorners both match `dock_spaces` on 26A434). Validate decoded targets and record Dock hash/UUID. Resolve private-call ownership from the callee and Dock's callers before changing retain/release (`doc/osax-prototypes.md`).

- **CF types in C structs** import as `Unmanaged<T>?` unless the header has nullability annotations. Use `CF_ASSUME_NONNULL_BEGIN/END` and mark optional fields `_Nullable` (`src/tab_bar_glass.h`). Take each value once with `takeUnretainedValue()` and let C free the struct.
- **CF ownership in C structs:** either Swift takes +1 references with `takeRetainedValue()` and C frees only memory, or Swift retains with `takeUnretainedValue()` and C releases. Choose per struct and document it in the header's NOTE. The pilot uses the latter (`tab_bar_glass_snapshot_free`).
- **Swift runtime rpath:** C/ObjC-driven linking of Swift objects needs `-Wl,-rpath,/usr/lib/swift`. Otherwise `@rpath/libswift_Concurrency.dylib` is weak-linked and missing, and `MainActor.assumeIsolated` crashes. Check `DYLD_PRINT_LIBRARIES=1 bin/yabai --version 2>&1 | grep Concurrency`. SwiftPM adds it; the C harness (`tests/makefile`) needs it explicitly.
- **Swift Build prelinks C targets** with `ld -r` into one object (`YabaiC.o`), making hidden symbols local. Do not use `-fvisibility=hidden` on YabaiC: Swift then cannot link C functions.
- **Swift Build adds Xcode's default warnings** (e.g. `-Wshorten-64-to-32`). `Package.swift` disables them to preserve the makefile warning set. After a toolchain update, disable new defaults there unless they reveal real bugs.
- **SDK version of the binary:** Swift Build's `--sysroot` does not tell clang the SDK version, so the binary can claim the deployment target as its SDK and AppKit treats it as old. `Package.swift` passes `-isysroot $SDKROOT` (set by xcrun's Swift shim and the makefile). `vtool -show-build bin/yabai | grep sdk` must show the SDK, e.g. 27.0.
- **Swift imports C headers with ARC.** Hide manual retain/release/`NSAutoreleasePool` bodies behind `#ifndef __swift__`, leaving Swift declarations (`src/misc/notify.h`). The importer also makes structs with ObjC pointer fields ARC structs: do not read those fields from Swift until the struct is Swift.
- **Missing `.pch` warnings:** a swiftc bridging header leaves debug info pointing to a temporary PCH; dsymutil warns it is missing. Use `-disable-bridging-pch` or a module map (the SwiftPM default used in P0).
- **Case-insensitive filesystem:** `Tests/` and `tests/` are the same. Swift tests use `tests/YabaiCoreTests` via `path:` in `Package.swift`.
- **Autolinking:** `import AppKit` autolinks many `libswift*` overlays. They are in the OS; do not trim them.
- **`@_cdecl` functions** accept only C-representable types (raw/typed C pointers, integers, `Bool`). Pass Swift objects as `Unmanaged.passRetained(obj).toOpaque()` and balance exactly one `release()` (`tab_bar_glass_create` / `tab_bar_glass_destroy`).
- **Main-queue blocks using Swift objects** must capture them strongly, as ObjC blocks did. The final pending block releases on the main queue. Release the C-held reference just after posting the final block (`tab_bar_glass_destroy`).
- **Unity-build static analysis:** clang skips included functions unless passed `-analyzer-opt-analyze-headers`; `make analyze` already does.
- **A C target without sources** does not link: Swift Build expects `<Target>.o`. `CPrivate.c` holds the function pointers resolved by `yabai.c`.
- **Nullability is per file:** after one annotation, clang requires all pointers annotated (`-Wnullability-completeness`), including macro expansions. `CONNECTION_CALLBACK` is unannotated; the `connection_callback` typedef carries qualifiers. Spell both levels of multi-level pointers inside `CF_ASSUME_NONNULL`, e.g. `CFTypeRef _Nullable *_Nonnull`.
- **Imported C types:** `Boolean` imports as `Bool`, `CGError` as an enum (`== .success`), CF out-parameters as `UnsafeMutablePointer<Unmanaged<T>?>` (use `takeRetainedValue()` for Copy/Create functions). See `Sources/Yabai/Platform/SkyLight.swift`.
- **Header functions touching `static` globals** cannot be called from Swift: Swift emits its own copy, which cannot link a unity-build static such as `_g_temp_storage`. Give Swift only a declaration (`#ifdef __swift__`) of a C wrapper, e.g. `ts_string_from_bytes` in `src/misc/ts.h`, used by `tsString` in `LabelShims.swift`.
- **Non-static header function bodies** also get a strong Swift copy and can produce duplicate symbols against `YabaiC.o` (former `memory_pool_init`). Use a `.c` wrapper or expose only a declaration to Swift (`ts_reset_storage` in `src/misc/ts.h`).
- **`String ==` is not `strcmp`:** Swift compares canonical equivalence (precomposed é equals e + U+0301). For byte comparisons (`string_equals`, `token_equals`), use `a.utf8.elementsEqual(b.utf8)` (`LabelList` in `Sources/YabaiCore/Label.swift`).
- **YabaiCore never imports YabaiC:** expose Swift types; put C-callable conversion shims in `Sources/Yabai/Shims/` (`Area(area)`, `SpaceLayout(space_layout)`). Fixed-size C arrays import as tuples: use `withUnsafe(Mutable)Bytes(of:)` (`SpaceLayoutShims.swift`). `tests/makefile` emits YabaiCore's module first, then builds Yabai with `-I ./bin`.
- **Mutable C globals:** Swift 6 rejects direct access as not concurrency-safe. Get their address with header `static inline` accessors (`window_manager_global()` in `src/globals.h`); the global itself must not be static.
- **Macros naming constants** do not import (`LAYER_BELOW kCGBackstopMenuLevelKey`), while literals (`LAYER_AUTO 0`) do. Use the imported constant (`CGWindowLevelKey.backstopMenu.rawValue`, `layerValue` in `MessageShims.swift`).
- **`&x` in `CVarArg...`** does not compile: inout-to-pointer conversion requires pointer parameters. Use `withUnsafeMutablePointer(to:)` or a buffer (`Grid.scan` in `Sources/YabaiCore/Rule.swift`, sscanf through `Token.scan`).
- **Names matching C types** (`rule`, `signal`, `token`, `window`, `properties`) shadow imported structs in parameters and locals. Use `result`, `first`, `target`, etc. (`parse_rule` in `MessageShims.swift`, `describeWindow` in `EventSignal.swift`). `let window = context!.assumingMemoryBound(to: window.self)` fails as use before declaration.
- **Executable tests:** `YabaiTests` depends on executable `Yabai` and uses `@testable import Yabai`. Swift Testing runs in parallel: tests changing global C managers must use `@Suite(.serialized)` (`MessageConfigTests.swift`) and avoid window-server calls.
- **Enum values in C `int` fields** import as `Int32`, not the enum (`window_animation_easing` in `window_manager`). Check the field declaration when `.rawValue` fails.
- **`fork()`, `environ`, `_NSGetEnviron` are unavailable in Swift.** Use `posix_spawn` with `environ_global()` from `src/globals.h` (`eventSignalSpawn`). Never run Swift in a forked child: only async-signal-safe code is safe before exec.
- **Custom global actors lack static `assumeIsolated`.** `WM.shared.assumeIsolated` cannot call `@WM` functions. `WM.assumeIsolated` (`EventLoop.swift`) uses `preconditionIsolated` and `unsafeBitCast`, like MainActor, and traps off `yabai.wm`. Its closure cannot capture non-Sendable raw pointers: use `Handoff` (`event_signal_push`). Test actor code with `@Test @WM func` (`goldenReplay`).
- **Swift has no atomics on C memory:** `Synchronization.Atomic` owns its storage. For C fields written atomically across threads, use inline C `__atomic_*` accessors (`process_is_terminated`); Swift-owned flags use global `let Atomic` values and `@_cdecl` setters (`pendingWindowFocus`). C `__atomic_sub_fetch` wraps: use `wrappingSubtract`/`wrappingAdd`, not trapping `subtract`/`add`.
- **`#expect` cannot capture non-copyable values** such as `Atomic`: save the operation's result to a `let` first (`mouse_event_coalescing` in `EventHandlerTests.swift`).
- **CF objects returned by `@_cdecl` are autoreleased (+0)** regardless of the C prototype (`-emit-sil` shows `@autoreleased`). For `CF_RETURNS_RETAINED`, return `Unmanaged<T>?` via `passRetained` from a differently named Swift function with `@_cdecl("c_name")`; use a normal Swift function for Swift callers (`displayUUIDRetained` / `displayUUID`).
- **Swift honors `CF_CONSUMED`:** it retains before the call (verified with `-emit-sil`). Pass owned objects normally (`takeRetainedValue()` then `window_manager_create_and_add_window`); do not add `retain()`.
- **Swift functions named like their C prototypes** shadow imports only with exactly matching types. Unannotated C pointers import as `T!`; returning `T` instead causes ambiguous calls. In tests importing YabaiC, they never shadow. Use a different Swift name with `@_cdecl("c_name")` (`spaceManagerFindView`, `viewCreate`) or qualify test calls as `Yabai.name`.
- **Shadowing drops implicit `@discardableResult`** from C imports. Add it explicitly or unused results warn (`view_remove_window`).
- **C enums:** anonymous `enum { kX = 1 }` imports as `Int` without `.rawValue`; `CF_ENUM` types like `CGEventField` import as structs with failable `init(rawValue:)`.
- **APIs unavailable to Swift** (`CGPostMouseEvent`, `CGEventCreate`, `CGEventPost`, `CGEventSetIntegerValueField`) can be called through inline CPrivate wrappers with deprecated warnings suppressed. Clang ignores Swift-only unavailability. Prefer Swift event methods where available (`CGEvent(source:)`, `post(tap:)`, `setIntegerValueField(_:value:)`).
- **APIs deprecated in macOS 10.9 or earlier** are unavailable to Swift, including Process Manager (`GetProcessPID`, `GetNextProcess`, `CopyProcessName`, `IsProcessVisible`, `SameProcess`). Use `Process*C` wrappers in `CPrivate.h`. Carbon Events (`InstallEventHandler`, `GetEventParameter`) work directly (`ProcessManager.swift`).
- **Swift cannot catch NSException:** unwinding through Swift terminates the process. Preserve ObjC `@try/@catch` via an inline wrapper under `#ifdef __OBJC__` in `CPrivate.h` (`NSObjectRemoveObserverC`, used by `Workspace.swift`). Swift's importer accepts that body.
- **Macros composed from macros** do not import (`AX_APPLICATION_ALL`, an OR of shifted indices). Spell the value in Swift with a comment naming the macro (`axApplicationAll` in `Application.swift`).
- **Global C function-pointer `let`s** (`table_hash_func`) are rejected in Swift 6: pass closures directly to `table_init`. Access C function-pointer variables through a CPrivate accessor (`SLSHasBridgedWindowOperation`).
- **`sel_registerName` returns `Selector`:** use `unsafeBitCast(sel, to: UnsafeMutableRawPointer.self)` for objc_msgSend casts (`SLS.bridgedMoveWindows`).
- **C callbacks** such as `CFComparatorFunction` get optional pointers; unwrap before `Unmanaged<T>.fromOpaque`.
- **Global CF `let`s** (`let x = "AXFullScreen" as CFString`) are not concurrency-safe in Swift 6. Keep a `String` and bridge at the call (`axFullscreenAttribute` in `Window.swift`).
- **Inline header functions reading `NDR_record`** link in debug but produce a release duplicate symbol: Swift's copy brings its own definition. Move bodies to `Sources/CPrivate/CPrivate.c`, with header declarations (`SLSGetWindowSubLevelBounded`). Run `make install` early in each phase.
- **`let wm = window_manager_global()`** infers an Optional, not an IUO. C callees accepted it implicitly; Swift callees with non-optional parameters do not. Write `window_manager_global()!` in the `let`; direct calls as arguments still implicitly unwrap.
- **C functions accepting NULL through helpers** must retain optional Swift parameters. No window is focused for some focus commands: `window_manager_find_tree_view(wm, NULL)` returns NULL and callers fail cleanly (`window_manager_tree_focus_*`, `window_manager_set_window_layout`, `window_manager_tree_split`).
- **Temporary C lists with counts** become Swift arrays when all callers are Swift (`window_space_list`, `window_manager_find_application_windows`). NULL-as-empty guards become `isEmpty` checks. Lists C still reads remain in temporary storage (`temporaryList` in `Display.swift`); `ts_buf` lists were removed in P12.
- **Swift tests have no temporary storage:** only the daemon and C harness call `ts_init`. Tests reaching `temporaryList` or `tsString` crash. Split out an array-returning Swift function and a C shim copying into temporary storage; test the Swift function (`treeViewWindowList` / `tree_view_window_list`).
- **Golden replay leaves config behind** on global managers in `DaemonState` (e.g. `tree_workspace_layout tabbed`). Later tests must set defaults explicitly; suite `init()` runs per test (`TreeTests`). The C harness ran replay last, hiding this issue.
- **Subscribe before initial tiling:** AX frame setters can return before WindowServer publishes the final frame. Register SkyLight notifications for new windows before tiling (`windowCreated`, `applicationLaunched`); otherwise the border can retain its creation frame until another move. Check intermediate window counts with `scripts/live-tests/border_geometry.swift`, since the next relayout can hide the bug.
- **Test calls need `Yabai.`** for every Swift function with a C prototype too (`Yabai.con_create`, `Yabai.tree_view_update`), since imports do not shadow in test targets. Functions whose C prototypes were removed need no prefix.
