import Foundation
import PackagePlugin

@main
struct OSAXEmbed: BuildToolPlugin
{
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command]
    {
        let root = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL
        let identityDirectory = output.appending(path: "toolchain")
        let identity = identityDirectory.appending(path: "Toolchain.h")
        let environment = ProcessInfo.processInfo.environment.filter {
            ["DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT"].contains($0.key)
        }
        let inputs = [
            "scripts/build-osax.sh",
            "scripts/osax-toolchain.sh",
            "osax/payload.m",
            "osax/loader.m",
            "osax/bootstrap.S",
            "osax/arm64_payload.m",
            "osax/common.h",
            "osax/core/IO.h",
            "osax/core/api/API.c",
            "osax/core/api/include/OSAXCore.h",
            "osax/core/api/include/module.modulemap",
            "osax/core/swift/Core.swift"
        ]

        return [.prebuildCommand(
            displayName: "Check the scripting-addition toolchain",
            executable: URL(filePath: "/bin/bash"),
            arguments: [root.appending(path: "scripts/osax-toolchain.sh").path, identity.path],
            environment: environment,
            outputFilesDirectory: identityDirectory
        ), .buildCommand(
            displayName: "Build and embed the arm64e scripting addition",
            executable: URL(filePath: "/bin/bash"),
            arguments: [root.appending(path: "scripts/build-osax.sh").path, output.path],
            environment: environment,
            inputFiles: inputs.map { root.appending(path: $0) } + [identity],
            outputFiles: [output.appending(path: "payload_bin.c"), output.appending(path: "loader_bin.c")]
        )]
    }
}
