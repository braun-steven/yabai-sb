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
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreVideo"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        .executableTarget(
            name: "Yabai",
            dependencies: ["YabaiC"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", Context.packageDirectory + "/assets/Info.plist"] + sdk)
            ]
        ),
        // tests/, not Tests/: on a case-insensitive file system both would be the directory of the C test harness
        .testTarget(
            name: "YabaiCoreTests",
            path: "tests/YabaiCoreTests",
            resources: [.copy("Golden")]
        )
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
