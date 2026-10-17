# Building yabai

Use Xcode with the macOS 27 SDK and Swift 6.4 on Apple Silicon. There are no external package
dependencies. SwiftPM owns the complete executable build, including the scripting addition,
compilation, linking, test discovery and debug/release optimization. Make provides convenience
commands for publishing to `bin/yabai`, documentation, signing and release archives.

## Commands

| Command | Result |
|---|---|
| `swift build` / `swift build -c release` | Complete debug/release build in SwiftPM's output directory |
| `swift test` | Daemon/core tests, including golden IPC replay |
| `swift run yabai --version` | Build and run the CLI's version command |
| `make` | Debug executable at `bin/yabai` |
| `make install` | Release executable at `bin/yabai`; no installation or service restart |
| `make asan` / `make tsan` | Debug executable with Address/ThreadSanitizer and C UndefinedBehaviorSanitizer |
| `make test` | Daemon/core tests, including golden IPC replay |
| `make osax-test` | Isolated payload/loader tests, outside Dock |
| `make osax-payload` | Standalone binaries/arrays in `.build/osax/swift/`; no injection |
| `make prepare` | Optional build of just the `OSAX` target through SwiftPM |
| `make clean` | Remove `bin/`, both packages' build caches and generated C sources |

Every daemon variant publishes to `bin/yabai` after a successful build. Copying to a temporary sibling
and renaming it preserves the last successful executable if compilation or copying fails. Other
`bin/` artifacts are retained. Make serializes goals because variants share this published path.

Debug/release use the normal `.build/` cache; sanitizer builds use `.build/asan` and `.build/tsan`.
Switching back to `make` cannot publish a cached sanitizer executable. The isolated package has its
own `osax/.build/` cache. `SWIFT` overrides the Swift command (default `xcrun swift`); `SWIFT_FLAGS`
passes additional SwiftPM options to builds and tests, for example `make test SWIFT_FLAGS='--filter Golden'`.

## Direct SwiftPM and editor use

SwiftPM and editor use require no preparation step, including on a fresh checkout or after native
source changes:

```sh
swift build
swift test --filter Golden
swift run yabai --version
```

The plugin tracks native sources, headers and the payload's Swift core automatically.
Direct SwiftPM commands leave their products in SwiftPM's output
directory; use `swift build --show-bin-path` to locate them.

## Embedded scripting addition

The daemon is an ordinary SwiftPM executable. The injected library uses arm64e, manual retain/release
in its native adapter, and a separately linked Swift core; the loader also contains assembly.
`Plugins/OSAXEmbed/` invokes `scripts/build-osax.sh` to build these binaries and convert them to
C arrays compiled by the `OSAX` target alongside `Version.c`.
The installed executable therefore contains everything it needs to load the scripting addition.

The plugin declares native sources, headers, the module map and script as inputs, and two C files
as outputs. SwiftPM runs it when an input changes or an output is missing. All generated files and
compiler caches stay in the sandboxed plugin work directory under `.build/`. Identical generated
arrays retain their timestamps to avoid unnecessary downstream compilation. Keep the input list
current when adding native dependencies. The standalone command uses the same script, so compiler
settings have one owner.

The root manifest explicitly opts into C generation:

```swift
// swift-tools-version: 6.4;(experimentalCGen)
```

This is an **experimental SwiftPM feature**, verified with the installed Swift 6.4 default Swift
Build backend and plugin sandbox enabled. Without the opt-in, SwiftPM warns
`C source file generation not enabled` and omits generated C sources. Keep the suffix when updating
the tools version.
See SwiftPM's [tools-version parser](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/ToolsVersionParser.swift)
and [generated-source handling](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/TargetSourcesBuilder.swift).

The script sets the historical `.build/osax/swift/payload` install name explicitly: Swift's default
includes the output path, which would otherwise change the previously tested payload bytes in
different plugin work directories. Run `make clean` when switching Xcode/SDK versions to discard
generated artifacts from the previous toolchain.

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

For build-system changes, check plain `swift build` and `swift test` after `make clean`, a second
build without native generation/compilation, all four daemon variants, both test
suites, unchanged golden IPC output, and `bin/yabai --version`. A deliberate failed build should
leave `bin/yabai` unchanged. Check the generated payload hash against the tested artifact.
Payload sanitizer tests run separately:

```sh
swift test --package-path osax --sanitize=address
swift test --package-path osax --sanitize=thread
```

Daemon sanitizers do not instrument binaries embedded as byte arrays. Builds and isolated tests
do not deploy, restart the service or inject into Dock. See [live testing](live-testing.md) before
any deployment; retain signing as an explicit step after building.
