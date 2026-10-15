# Repository Guidelines

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
- `osax/`: scripting-addition payload/loader sources. The makefile builds arm64e binaries and generates `payload_bin.c` / `loader_bin.c`; the SwiftPM `OSAX` target embeds those arrays and exposes `common.h` through `include/OSAX.h`.
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

## Architecture

**Targets and startup.** SwiftPM builds the executable `Yabai`, pure library `YabaiCore`, and C targets `CPrivate` and `OSAX`. There is no unity build or YabaiC bridge. `Yabai.swift` preserves the original startup sequence and `Service.swift` the launchd commands. Constants and formerly shared small structs live in `Definitions.swift`, shared math and string helpers in `Helpers.swift`. CPrivate wrappers preserve unavailable or deprecated calls and ObjC exception handling. Private +1 CF functions need `CF_RETURNS_RETAINED` even when their names lack Copy/Create.

**Models and managers.** `WindowManager`, `SpaceManager`, `DisplayManager`, `ProcessManager` and `MouseState` own Swift state. Their globals/accessors live with the managers. `Window`, `Application`, `Process`, `View`, `Con` and `TabBar` are reference models with identity equality and ARC lifetimes. `Table.swift` preserves the old C hash-table bucket, insertion and rehash iteration order because query JSON depends on it; do not substitute a Dictionary. Labels use `LabelList`, lists use arrays. Rules remain Swift `rule` / `rule_effects` values behind explicit heap pointers.

**Window, space and process logic.** `WindowManager*.swift` covers discovery, lookup, focus, rules, scratchpads and tree commands. `Display*.swift`, `Space*.swift` and `View.swift` manage displays, spaces and layouts; `SpaceLayout.swift` reconciles configured space counts. `ProcessManager.swift` receives Carbon application events; `Workspace.swift` observes NSWorkspace and NSRunningApplication. `Window.swift` and `Application.swift` wrap individual AX/SkyLight objects and AX notifications.

**Tree layout.** Each `View` owns a container tree. `Con` has a weak parent and ordered children/focus arrays; `Tree.swift` implements the i3 operations one-to-one. `TreeView.swift` applies frames, tab bars and stacking; `WindowManagerTree.swift` implements navigation and cross-display moves. `ViewArea` in YabaiCore handles pure geometry.

**Event loop and isolation.** `EventLoop.swift` serializes handlers on the `yabai.wm` dispatch executor of `@WM`. Producers post an `Event` with associated values from AX, Carbon, SkyLight, NSWorkspace/KVO, the mouse event tap and the IPC thread. Never use `Task {}` for events: it can reorder them. Handlers in `EventHandlers*.swift` run synchronously, then flush signals. To add an event, add its enum case, dispatch case and handler. `MissionControl.swift` owns the Dock observer and connection callback. Cross-thread flags use Swift Atomics. The process table retains the original main-thread Carbon/event-loop access pattern; do not assume the whole legacy model is compiler-enforced actor isolation.

**IPC / CLI.** `Client.swift` sends argument bytes over `/tmp/yabai_$USER.socket`. `MessageLoop.swift` accepts connections and posts daemon-message events. Handlers parse `Message`, write `Response`, throw `CommandError.fail` and call Swift managers. YabaiCore holds parsers, selectors, labels and rule/signal logic; `CSelectorContext` in `Shims/MessageShims.swift` connects selectors to models. `Serialize.swift`, YabaiCore's `WindowInfo` and `Rule.swift` write ordered JSON. New commands need handler parsing, `doc/yabai.asciidoc` documentation (`make man`), and usually a CHANGELOG entry.

**Rules and signals.** `Rule.swift` matches rules and serializes `rule --list`; `WindowManagerRules.swift` applies effects. YabaiCore's `EventSignal.swift` holds signal filters and JSON; the executable's `EventSignal.swift` queues and flushes commands with `posix_spawn` through `env`. Config scripts also use `posix_spawn`; Swift must never execute in a forked child.

**Rendering and input.** `Border.swift` owns four edge windows per border under a Mutex; SkyLight callbacks move them without reading the tree. `TabBar.swift` draws classic bars and publishes immutable hit-test snapshots under a Mutex. `TabBarGlass.swift` snapshots on the event loop and renders with AppKit on the main queue. `WindowAnimation.swift` retains AX references and copied app names for concurrent frame workers, stores window ids for animations, and protects proxy/takeover state with a Mutex. `MouseHandler.swift` owns the event tap and drag/drop decisions. Main-queue blocks retain their render owners until the last pending block completes.

**Scripting addition.** `osax/loader.m` injects `payload.m` into Dock.app. The payload serves `/tmp/yabai-sa_$USER.socket`; `ScriptingAddition.swift` builds the unchanged length-prefixed protocol using `SA_OPCODE_*` from `osax/common.h`. macOS 27 patterns/offsets are in `osax/arm64_payload.m`. Bump `OSAX_VERSION` when payload protocol or behavior changes; a path-only rebuild in P14 preserved 2.1.34 and needs no reload. See `doc/payload-updates.md`.

**Platform gating.** The supported target is macOS 27 on arm64; the injected payload is arm64e. `verify_os_version` in `osax/payload.m` accepts macOS 27 only. Add version branches only when a newer release needs different behavior.

## Commit & Pull Request Guidelines
- Commit directly to `master`; no feature branches needed, unless the user asks for a separate branch (e.g. for experimental work).
- Commits commonly use concise, imperative subjects, often prefixed with an issue/PR id (e.g. `#1234 fix …`) or a version tag (e.g. `v7.1.16`).
- PRs should include: macOS version + arch, repro steps, expected vs actual behavior, and any relevant logs/output (e.g. `bin/yabai --version`, `--verbose` when appropriate).
