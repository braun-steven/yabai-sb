---
name: swift-port-conventions
description: Conventions and pitfalls for writing Swift in the yabai Swift port (branch swift-port, doc/swift-port.md). Read before writing or reviewing Swift, C/Swift bridges, Package.swift or CPrivate changes, and add new pitfalls here.
---

# Swift conventions and pitfalls of the yabai port

Read this before writing Swift on branch `swift-port`. Keep each entry to a few lines with a pointer to an example. When something costs real time, add it here in the same commit and note it in the Handoff log of `doc/swift-port.md`.

## Toolchain
Swift 6.4 on macOS 27 is near the edge of the model's training data. For recent features (SwiftPM concurrency defaults, `isolated deinit`, `Mutex`/`Atomic`, custom executors), trust `swift --version`, the compiler diagnostics and the SDK interfaces over memory. When unsure, try it in a scratch file first.

## Conventions
- **Performance:** prefer `final class` and structs on hot paths (mouse drag, animations, tree updates). Avoid existentials (`any P`) and closures that capture state in loops there.
- **Isolation:**
  - `@MainActor` only for AppKit code.
  - Window manager state is `@WM`.
  - Plain value types are `Sendable` without annotations.
- **Unit tests:** Swift Testing (`import Testing`, `@Test`, `#expect`, `#require`). Name a test after the C `TEST_FUNC` it replaces, so the ledger stays countable.
- **Errors:**
  - Command handlers `throw CommandError.fail(...)`.
  - Platform wrappers return optionals or `Bool` like the C code did. Don't invent new error types for AX/SkyLight failures.
- **Style:** keep the C file's order of functions in the Swift file, so diffs against the C original stay readable during review.

## Pitfalls learned so far
- **CF types in C structs** import as `Unmanaged<T>?` unless the header has nullability annotations. Wrap the header in `CF_ASSUME_NONNULL_BEGIN/END` and mark the optional fields `_Nullable` (example: `src/tab_bar_glass.h`). Then take each value once with `takeUnretainedValue()` and let C free the struct.
- **Who frees a C struct's CF objects:** either Swift takes the +1 references (`takeRetainedValue()`) and C only frees the memory, or Swift retains (`takeUnretainedValue()`) and C releases. Pick one per struct and write it in the header's NOTE. The pilot uses the second way (`tab_bar_glass_snapshot_free`).
- **Swift runtime rpath:** a C/ObjC-driven link of Swift objects needs `-Wl,-rpath,/usr/lib/swift`. Otherwise `@rpath/libswift_Concurrency.dylib` is weak-linked and silently missing, and `MainActor.assumeIsolated` crashes. Check with `DYLD_PRINT_LIBRARIES=1 bin/yabai --version 2>&1 | grep Concurrency`. SwiftPM adds the rpath itself (checked in P0); it matters again only for the C test harness (`tests/makefile`).
- **Swift Build prelinks each C target** with `ld -r` into one object (`YabaiC.o`), which turns hidden symbols into local ones. With `-fvisibility=hidden` on YabaiC, Swift fails to link against any C function ("Undefined symbols"). YabaiC is therefore built without it.
- **Swift Build adds Xcode's default warnings** to C targets (e.g. `-Wshorten-64-to-32`, 38 hits). `Package.swift` turns those off to keep the makefile's warning set. A new default warning shows up after a toolchain update: switch it off there, unless it finds a real bug.
- **SDK version of the binary:** Swift Build links with `--sysroot`, from which clang does not read the SDK version, so the binary claims an SDK as old as its deployment target, and AppKit may treat it as an old app. `Package.swift` passes `-isysroot $SDKROOT` (set by xcrun's `swift` shim and by the makefile). Check with `vtool -show-build bin/yabai | grep sdk` (must be the SDK, e.g. 27.0).
- **Swift imports C headers with ARC.** A header body with manual `retain`/`release`/`NSAutoreleasePool` fails to import ("ARC forbids…"); hide it behind `#ifndef __swift__` and leave Swift a declaration (`src/misc/notify.h`). The importer also builds structs with ObjC pointer fields as ARC structs, so do not read such fields from Swift until the struct is Swift.
- **Missing `.pch` warnings:** a bridging header compiled by `swiftc` leaves debug info pointing at a temporary PCH, and dsymutil warns "`….pch: No such file or directory`". Use `-disable-bridging-pch`, or a module map, which is the SwiftPM default (and what P0 uses).
- **Case-insensitive file system:** `Tests/` and `tests/` are the same directory. The Swift tests live in `tests/YabaiCoreTests` (`path:` in `Package.swift`).
- **Autolinking:** `import AppKit` autolinks dozens of `libswift*` overlays. That is harmless (they are in the OS); don't try to trim them.
- **`@_cdecl` functions** must use C-representable types only (`UnsafeMutableRawPointer`, `UnsafeMutablePointer<cstruct>`, integers, `Bool`). Pass Swift objects through C as `Unmanaged.passRetained(obj).toOpaque()`, and balance that with exactly one `release()` (example: `tab_bar_glass_create` / `tab_bar_glass_destroy`).
- **Main-queue blocks that use a Swift object** must capture it strongly, like the ObjC blocks retained it. The last pending block then releases the object, on the main queue. Release the C-held reference right after posting the final block (`tab_bar_glass_destroy`).
- **Static analysis of the unity build:** clang's analyzer skips functions in `#include`d files unless you pass `-analyzer-opt-analyze-headers`. `make analyze` already does.
- **A C target without sources** does not link: Swift Build still expects its `<Target>.o`. `CPrivate` therefore has `CPrivate.c`, which holds the function pointers that `yabai.c` resolves at runtime.
- **Nullability is per file:** once one pointer of a file has a nullability qualifier, clang wants one on every pointer of that file (`-Wnullability-completeness`), including pointers from macros expanded there. `CONNECTION_CALLBACK` (`CPrivate.h`) is therefore unannotated, and the `connection_callback` typedef carries the `_Nullable`s. A multi-level pointer inside `CF_ASSUME_NONNULL` needs both levels spelled out (`CFTypeRef _Nullable *_Nonnull`).
- **Imported C types:** `Boolean` imports as `Bool`, `CGError` as an enum (`== .success`), CF out-parameters as `UnsafeMutablePointer<Unmanaged<T>?>` (take the value with `takeRetainedValue()` in a Copy/Create function). Examples in `Sources/Yabai/Platform/SkyLight.swift`.
- **Header functions that touch `static` globals** cannot be called from Swift. Swift emits its own copy of every header function it calls (also non-inline ones with a body), and that copy cannot link against a global that is `static` in the unity build (`Undefined symbols: _g_temp_storage`). Give Swift a declaration only (`#ifdef __swift__`) of a C wrapper; for temporary storage that is `ts_string_from_bytes` (`src/misc/ts.h`, used by `tsString` in `Sources/Yabai/Shims/LabelShims.swift`).
- **Header functions with a body that are not `static`** (e.g. `memory_pool_init` in `src/misc/memory_pool.h`) link twice when Swift calls them: Swift's copy is a strong symbol too, and the test target fails with "duplicate symbol '_memory_pool_init'" against `YabaiC.o`. Call a wrapper defined in a `.c` file instead (`event_signal_storage_init` in `src/event_signal.c`).
- **`String ==` is not `strcmp`:** Swift compares strings by canonical equivalence ("é" precomposed equals "e" + U+0301). Where C compared bytes (`string_equals`, `token_equals`), compare `a.utf8.elementsEqual(b.utf8)` (`LabelList` in `Sources/YabaiCore/Label.swift`).
- **YabaiCore does not import YabaiC.** Its API is Swift types; the `@_cdecl` shim for a C caller lives in `Sources/Yabai/Shims/` and converts the C struct (`Area(area)`, `SpaceLayout(space_layout)`). Fixed-size C arrays import as tuples: read and write them with `withUnsafe(Mutable)Bytes(of:)` (`SpaceLayoutShims.swift`). `tests/makefile` builds YabaiCore as its own module first (`-emit-module-path`), then the Yabai sources with `-I ./bin`.
- **Mutable C globals:** Swift 6 rejects every reference to an imported C global variable ("reference to var 'g_window_manager' is not concurrency-safe"). The shims take the address through a `static inline` accessor in a header (`window_manager_global()` in `src/globals.h`), which works because the global is not `static`.
- **Macros that name another constant** do not import: `#define LAYER_BELOW kCGBackstopMenuLevelKey` is missing in Swift, while `#define LAYER_AUTO 0` imports. Use the imported constant itself (`CGWindowLevelKey.backstopMenu.rawValue`, `layerValue` in `Sources/Yabai/Shims/MessageShims.swift`).
- **`&x` in a `CVarArg...` list** does not compile (inout-to-pointer only converts for pointer parameters). Pass real pointers from `withUnsafeMutablePointer(to:)` or a buffer (`Grid.scan` in `Sources/YabaiCore/Rule.swift`, sscanf through `Token.scan`).
- **Parameter names that are C type names** (`rule`, `signal`, `token`, `window`, `properties`) shadow the imported struct in the function body, e.g. `WritableKeyPath<rule, …>` then fails. Name such parameters `result`, `first`, … (`parse_rule` in `MessageShims.swift`).
- **Testing code of the executable:** the test target `YabaiTests` depends on the executable target `Yabai` and uses `@testable import Yabai` (works with Swift Build, checked in P5). Swift Testing runs tests in parallel; tests that change the C managers go in a `@Suite(.serialized)` (`tests/YabaiTests/MessageConfigTests.swift`), and must not reach code that needs the window server.
- **C fields that hold an enum as `int`** (`window_animation_easing` in `struct window_manager`) import as `Int32`, not as the enum type. Check the field's declaration, not the enum, when the compiler says "has no member 'rawValue'".
