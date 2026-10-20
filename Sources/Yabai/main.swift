import Foundation

//
// NOTE: `yabai -m` / `yabai --message` is the client (IPC/Client.swift); everything else is the daemon and its other
// options (Daemon.run in Yabai.swift).
//

let argv = CommandLine.unsafeArgv
if CommandLine.argc > 1, let option = argv[1], strcmp(option, "--message") == 0 || strcmp(option, "-m") == 0 {
    let arguments = (2..<Int(CommandLine.argc)).map { Array(UnsafeRawBufferPointer(start: argv[$0]!, count: strlen(argv[$0]!))) }
    exit(Client.send(arguments))
}

Log.bootstrap()
exit(Daemon.run(CommandLine.arguments))
