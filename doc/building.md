# Building yabai

Use Xcode with the macOS 27 SDK and Swift 6.4 on Apple Silicon. There are no external package
dependencies. SwiftPM owns target dependencies, compilation, linking, test discovery and debug/release
optimization. The makefile handles the arm64e binaries embedded in the arm64 executable, documentation,
signing and release archives.

## Commands

| Command | Result |
|---|---|
| `make` | Debug executable at `bin/yabai` |
| `make install` | Release executable at `bin/yabai`; no installation or service restart |
| `make asan` / `make tsan` | Debug executable with Address/ThreadSanitizer and C UndefinedBehaviorSanitizer |
| `make test` | Daemon/core tests, including golden IPC replay |
| `make osax-test` | Isolated payload/loader tests, outside Dock |
| `make osax-payload` | Standalone arm64e payload at `.build/osax/swift/payload`; no injection |
| `make prepare` | Generate the embedded payload/loader C sources |
| `make clean` | Remove `bin/`, both packages' build caches and generated C sources |

Every daemon variant publishes to `bin/yabai` after a successful build. Copying to a temporary sibling
and renaming it preserves the last successful executable if compilation or copying fails. Other
`bin/` artifacts are retained. Make serializes goals because variants share this published path.

Debug/release use the normal `.build/` cache; sanitizer builds use `.build/asan` and `.build/tsan`.
Switching back to `make` cannot publish a cached sanitizer executable. The isolated package has its
own `osax/.build/` cache. `SWIFT` overrides the Swift command (default `xcrun swift`); `SWIFT_FLAGS`
passes additional SwiftPM options to builds and tests, for example `make test SWIFT_FLAGS='--filter Golden'`.

## Direct SwiftPM and editor use

Run preparation before opening `Package.swift` in an editor or using SwiftPM directly:

```sh
make prepare
swift build --product yabai
swift test --filter Golden
swift run yabai --version
```

Rerun `make prepare` after changing native payload/loader sources, headers or the payload's Swift
core. Ordinary daemon edits need no preparation. `make` and `make test` always check preparation
dependencies automatically. Direct SwiftPM commands leave their products in SwiftPM's output
directory; use `swift build --show-bin-path` to locate them.

## Why a native preparation step remains

The daemon is an ordinary SwiftPM executable. The injected library uses arm64e, manual retain/release
in its native adapter, and a separately linked Swift core; the loader also contains assembly. Make
builds these two binaries, then `xxd` converts them to the C arrays compiled by the `OSAX` target.
The installed executable therefore contains everything it needs to load the scripting addition.

SwiftPM build tool plugins are normally the right place for generated sources:
they declare inputs and outputs and keep generated files in their work directory.
However, a minimal probe on the installed Swift 6.4 default Swift Build backend reports
`C source file generation not enabled` and omits a plugin-generated C source from the target.
Keep the small Make boundary until the supported toolchain can build these generated sources.
Do not add a plugin that silently drops the embedded binaries or requires disabling its sandbox.
See [SwiftPM's build tool plugin design](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md).

The native recipes list their source/header/module-map inputs and depend on the makefile itself,
so changing compiler flags rebuilds the binaries. Keep those prerequisites current when adding
native inputs. Run `make clean` when switching Xcode/SDK versions; Make does not track toolchain
identity. `.DELETE_ON_ERROR` removes incomplete outputs after a failed native build or generation.
Keep the payload output path stable: Swift's library linker uses it as the default install name,
so even relocating an otherwise identical build changes the embedded artifact.

## Settings and verification

Both package manifests use Swift 6 language mode and the supported
[`treatAllWarnings(as:)` setting](https://developer.apple.com/documentation/packagedescription/swiftsetting/treatallwarnings(as:_:))
for Swift and C targets. SwiftPM selects optimization for the requested configuration; CPrivate
only adds `NDEBUG` for release. The injected payload retains its tested explicit native compiler
settings. Remaining unsafe flags express private-framework search paths, manual ObjC ownership,
selected C diagnostics and the embedded Info.plist/SDK linker workaround.

Make exports the selected macOS `SDKROOT`; the Xcode `swift` shim also supplies it for direct commands.
`Package.swift` forwards `-isysroot` to the Clang linker so the executable records the actual SDK
version and AppKit does not enable old-SDK compatibility behavior. Check it with
`xcrun vtool -show-build bin/yabai` after toolchain changes.

For build-system changes, check clean and incremental builds, all four daemon variants, both test
suites, unchanged golden IPC output, and `bin/yabai --version`. A deliberate failed build should
leave `bin/yabai` unchanged. Payload sanitizer tests run separately:

```sh
swift test --package-path osax --sanitize=address
swift test --package-path osax --sanitize=thread
```

Daemon sanitizers do not instrument binaries embedded as byte arrays. Builds and isolated tests
do not deploy, restart the service or inject into Dock. See [live testing](live-testing.md) before
any deployment; retain signing as an explicit step after building.
