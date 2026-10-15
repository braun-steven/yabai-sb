// swift-tools-version: 6.2
import PackageDescription

//
// NOTE: The makefile drives this package (make, make install, make asan, make tsan, make test); see AGENTS.md. yabai is
// Swift (Sources/Yabai, Sources/YabaiCore); the C targets only declare the private framework functions (CPrivate) and
// hold the scripting-addition binaries (OSAX).
//

//
// NOTE: Swift Build links with --sysroot, from which clang does not read the SDK version, so the binary would claim to be
// built against an SDK as old as its deployment target, and AppKit would turn on its compatibility behavior for old apps
//. -isysroot fixes the version. The swift shim of xcrun sets SDKROOT; so does the makefile.
//

let sdk = Context.environment["SDKROOT"].map { ["-Xclang-linker", "-isysroot", "-Xclang-linker", $0] } ?? []

let warnings = ["-Wall", "-Wextra", "-Wstrict-prototypes", "-Wimplicit-fallthrough", "-Wnull-dereference", "-Wno-shorten-64-to-32"]

let package = Package(
    name: "yabai",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "yabai", targets: ["Yabai"])
    ],
    targets: [
        // the declarations of the private functions yabai calls, the pointers to the ones it resolves at runtime, and the
        // wrappers of the calls that Swift cannot make (Notify.m uses manual retain/release)
        .target(
            name: "CPrivate",
            cSettings: [
                .unsafeFlags(warnings + ["-fno-objc-arc"]),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
                .define("NDEBUG", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        // the scripting addition: its opcodes (common.h) and the payload and loader binaries that the makefile builds
        // (payload.m and loader.m are not sources of the package)
        .target(
            name: "OSAX",
            path: "osax",
            sources: ["payload_bin.c", "loader_bin.c"],
            publicHeadersPath: "include"
        ),
        // the pure logic of the daemon (no window server access), unit-tested by YabaiCoreTests
        .target(
            name: "YabaiCore"
        ),
        .executableTarget(
            name: "Yabai",
            dependencies: ["CPrivate", "OSAX", "YabaiCore"],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreServices"),
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/assets/Info.plist"] + sdk)
            ]
        ),
        // tests/, not Tests/: the file system is case-insensitive
        .testTarget(
            name: "YabaiCoreTests",
            dependencies: ["YabaiCore"],
            path: "tests/YabaiCoreTests"
        ),
        // the code of the daemon (the IPC handlers, the managers and the golden replay), through @testable import Yabai
        .testTarget(
            name: "YabaiTests",
            dependencies: ["CPrivate", "OSAX", "Yabai", "YabaiCore"],
            path: "tests/YabaiTests",
            resources: [.copy("Golden")]
        )
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
