import Foundation
import PackagePlugin

@main
struct OSAXEmbed: BuildToolPlugin
{
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command]
    {
        let root = context.package.directoryURL
        let output = context.pluginWorkDirectoryURL
        let inputs = [
            "scripts/build-osax.sh",
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

        return [.buildCommand(
            displayName: "Build and embed the arm64e scripting addition",
            executable: URL(filePath: "/bin/bash"),
            arguments: [root.appending(path: "scripts/build-osax.sh").path, output.path],
            inputFiles: inputs.map { root.appending(path: $0) },
            outputFiles: [output.appending(path: "payload_bin.c"), output.appending(path: "loader_bin.c")]
        )]
    }
}
