import ArgumentParser
import Foundation

//
// NOTE: `yabai -m` / `yabai --message` is the client (IPC/Client.swift). It sends the raw bytes of its arguments and
// runs on every key binding, so it skips swift-argument-parser; everything else is parsed by YabaiOptions and runs the
// daemon or one of its other options (Daemon.run in Yabai.swift).
//

let argv = CommandLine.unsafeArgv
if CommandLine.argc > 1, let option = argv[1],
  strcmp(option, "--message") == 0 || strcmp(option, "-m") == 0
{
  let arguments = (2..<Int(CommandLine.argc)).map {
    Array(UnsafeRawBufferPointer(start: argv[$0]!, count: strlen(argv[$0]!)))
  }
  exit(Client.send(arguments))
}

let options = YabaiOptions.parseOrExit()
if !options.message.isEmpty {
  exit(Client.send(options.message.map { Array($0.utf8) }))
}

//
// NOTE: --check-config reads a yabai.toml on the @WM queue, with no daemon and no window server, so it runs before
// Log.bootstrap and the actions. WM.sync is the way the startup runs @WM code from the main thread.
//
if options.checkConfig {
  let file = options.checkConfigFile
  exit(WM.sync { checkConfigOffline(file) })
}

Log.bootstrap()

//
// NOTE: The actions wait for their commands through swift-subprocess, which is async only. A task on the main actor runs
// the action while dispatchMain serves the main queue; the daemon stays synchronous and never runs in an async context.
//

if let action = options.action {
  Task { exit(await action.run()) }
  dispatchMain()
}

exit(Daemon.run(options))
