// swift-tools-version: 6.2
import PackageDescription

// Isolated payload tests: the recording adapter has no SkyLight dependency, Dock constructor or
// real window IDs. Sanitizers here instrument the payload cores, unlike the daemon's sanitizer build.
let package = Package(
    name: "OSAXPrototypes",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "osax-benchmark", targets: ["Benchmark"])],
    targets: [
        .target(name: "OSAXCoreAPI", path: "core/api"),
        .target(name: "ObjCPayloadCore", dependencies: ["OSAXCoreAPI"], path: "core/objc",
                publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fno-objc-arc", "-Wall", "-Wextra", "-Werror"])],
                linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "SwiftPayloadCore", dependencies: ["OSAXCoreAPI"], path: "core/swift"),
        .target(name: "RecordingAdapter", dependencies: ["OSAXCoreAPI"], path: "testing/adapter",
                cSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])]),
        .target(name: "Fixtures", dependencies: ["OSAXCoreAPI"], path: "testing/fixtures"),
        .target(name: "LoaderFixture", path: "testing/loader", exclude: ["Mocks.h"],
                cSettings: [.unsafeFlags(["-fno-objc-arc", "-Wall", "-Wextra", "-Werror"])],
                linkerSettings: [.linkedFramework("Cocoa")]),
        .executableTarget(name: "Benchmark", dependencies: ["OSAXCoreAPI", "ObjCPayloadCore", "SwiftPayloadCore", "RecordingAdapter", "Fixtures"], path: "testing/benchmark"),
        .testTarget(name: "PayloadTests", dependencies: ["OSAXCoreAPI", "ObjCPayloadCore", "SwiftPayloadCore", "RecordingAdapter", "Fixtures", "LoaderFixture"], path: "testing/tests")
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
