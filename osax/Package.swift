// swift-tools-version: 6.2
import PackageDescription

let swiftSettings: [SwiftSetting] = [.treatAllWarnings(as: .error)]
let cSettings: [CSetting] = [.treatAllWarnings(as: .error)]

// Isolated payload tests: the recording adapter has no SkyLight dependency, Dock constructor or
// real window IDs. Sanitizers here instrument the payload core, unlike the daemon's sanitizer build.
let package = Package(
    name: "OSAXPayload",
    platforms: [.macOS("27.0")],
    products: [.executable(name: "osax-benchmark", targets: ["Benchmark"])],
    targets: [
        .target(name: "OSAXCoreAPI", path: "core/api", cSettings: cSettings),
        .target(name: "SwiftPayloadCore", dependencies: ["OSAXCoreAPI"], path: "core/swift", swiftSettings: swiftSettings),
        .target(name: "RecordingAdapter", dependencies: ["OSAXCoreAPI"], path: "testing/adapter",
                cSettings: cSettings + [.unsafeFlags(["-Wall", "-Wextra"])]),
        .target(name: "Fixtures", dependencies: ["OSAXCoreAPI"], path: "testing/fixtures", cSettings: cSettings),
        .target(name: "LoaderFixture", path: "testing/loader", exclude: ["Mocks.h"],
                cSettings: cSettings + [.unsafeFlags(["-fno-objc-arc", "-Wall", "-Wextra"])],
                linkerSettings: [.linkedFramework("Cocoa")]),
        .executableTarget(name: "Benchmark", dependencies: ["OSAXCoreAPI", "SwiftPayloadCore", "RecordingAdapter", "Fixtures"], path: "testing/benchmark", swiftSettings: swiftSettings),
        .testTarget(name: "PayloadTests", dependencies: ["OSAXCoreAPI", "SwiftPayloadCore", "RecordingAdapter", "Fixtures", "LoaderFixture"], path: "testing/tests", swiftSettings: swiftSettings)
    ],
    swiftLanguageModes: [.v6],
    cLanguageStandard: .c11
)
