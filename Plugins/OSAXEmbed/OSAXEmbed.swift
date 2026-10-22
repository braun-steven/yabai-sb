import Foundation
import PackagePlugin

enum OSAXEmbedError: Error, CustomStringConvertible {
  case unreadable(String)

  var description: String {
    switch self {
    case .unreadable(let path): return "cannot enumerate the scripting addition sources at \(path)"
    }
  }
}

@main
struct OSAXEmbed: BuildToolPlugin {
  // Every file under osax/ with one of these extensions is a native input of the payload or loader, except the
  // top-level entries below: the standalone test package and its testing sources, the public header of the OSAX
  // target, and Version.c, which only the OSAX target compiles. The generated arrays are never inputs.
  private static let nativeExtensions: Set<String> = ["m", "c", "h", "S", "swift", "modulemap"]
  private static let excludedTopLevel: Set<String> = [
    ".build", "testing", "include", "Package.swift", "Version.c",
  ]
  private static let generatedFiles: Set<String> = ["payload_bin.c", "loader_bin.c"]

  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let root = context.package.directoryURL
    let output = context.pluginWorkDirectoryURL
    let identityDirectory = output.appending(path: "toolchain")
    let identity = identityDirectory.appending(path: "Toolchain.h")
    let environment = ProcessInfo.processInfo.environment.filter {
      ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"].contains($0.key)
    }
    let inputs =
      try [
        "scripts/build-osax.sh",
        "scripts/osax-toolchain.sh",
      ] + nativeSources(in: root)

    return [
      .prebuildCommand(
        displayName: "Check the scripting-addition toolchain",
        executable: URL(filePath: "/bin/bash"),
        arguments: [root.appending(path: "scripts/osax-toolchain.sh").path, identity.path],
        environment: environment,
        outputFilesDirectory: identityDirectory
      ),
      .buildCommand(
        displayName: "Build and embed the arm64e scripting addition",
        executable: URL(filePath: "/bin/bash"),
        arguments: [root.appending(path: "scripts/build-osax.sh").path, output.path],
        environment: environment,
        inputFiles: inputs.map { root.appending(path: $0) } + [identity],
        outputFiles: [
          output.appending(path: "payload_bin.c"), output.appending(path: "loader_bin.c"),
        ]
      ),
    ]
  }

  // Paths relative to the package root, sorted so the build graph is the same on every run.
  private func nativeSources(in root: URL) throws -> [String] {
    let osax = root.appending(path: "osax")
    let prefix = osax.path + "/"
    guard
      let enumerator = FileManager.default.enumerator(
        at: osax, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
      )
    else {
      throw OSAXEmbedError.unreadable(osax.path)
    }

    var sources: [String] = []
    for case let url as URL in enumerator {
      guard url.path.hasPrefix(prefix) else {
        throw OSAXEmbedError.unreadable(url.path)
      }
      let relative = String(url.path.dropFirst(prefix.count))
      let topLevel = relative.split(separator: "/").first.map(String.init) ?? relative
      guard !Self.excludedTopLevel.contains(topLevel) else {
        continue
      }
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        continue
      }
      guard Self.nativeExtensions.contains(url.pathExtension),
        !Self.generatedFiles.contains(url.lastPathComponent)
      else {
        continue
      }
      sources.append("osax/" + relative)
    }
    return sources.sorted()
  }
}
