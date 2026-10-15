// swift-tools-version: 6.2
import PackageDescription

//
// NOTE: The makefile drives this package (make, make install, make asan, make tsan, make test); see doc/swift-port.md.
// The C target YabaiC is the unity build of src/ (manifest.m plus the generated scripting-addition byte arrays). It shrinks
// while the port moves code to Swift, and Swift sees its headers through src/include/yabai_c.h.
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
        .target(
            name: "YabaiC",
            dependencies: ["CPrivate"],
            path: "src",
            sources: ["manifest.m", "osax/payload_bin.c", "osax/loader_bin.c"],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(warnings + ["-fno-objc-arc", "-F/System/Library/PrivateFrameworks"]),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
                .define("NDEBUG", .when(configuration: .release))
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreServices")
            ]
        ),
        // the declarations of the private functions yabai calls, and the pointers to the ones it resolves at runtime
        .target(
            name: "CPrivate",
            linkerSettings: [
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        // the pure logic of the daemon (no window server access), unit-tested by YabaiCoreTests
        .target(
            name: "YabaiCore"
        ),
        .executableTarget(
            name: "Yabai",
            dependencies: ["CPrivate", "YabaiC", "YabaiCore"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/assets/Info.plist"] + sdk)
            ]
        ),
        // tests/, not Tests/: on a case-insensitive file system both would be the directory of the C test harness
        .testTarget(
            name: "YabaiCoreTests",
            dependencies: ["YabaiCore"],
            path: "tests/YabaiCoreTests"
        ),
        // the code of the daemon that needs the C managers (the IPC handlers and the golden replay), through @testable import Yabai
        .testTarget(
            name: "YabaiTests",
            dependencies: ["Yabai", "YabaiC", "YabaiCore"],
            path: "tests/YabaiTests",
            resources: [.copy("Golden")]
        )
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
