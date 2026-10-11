import AppKit
// usage: freeze <bundle id> -> launches the application and stops it the moment it has finished
// launching, before a window manager gets to observe it. Prints the pid.
let id = CommandLine.arguments[1]
guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { exit(1) }
var observation: NSKeyValueObservation?
var running: NSRunningApplication?
let config = NSWorkspace.OpenConfiguration()
config.activates = false
NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
    guard let app = app else { exit(1) }
    running = app
    if app.isFinishedLaunching { kill(app.processIdentifier, SIGSTOP); print(app.processIdentifier, "late"); exit(0) }
    observation = app.observe(\.isFinishedLaunching, options: [.new]) { a, _ in
        if a.isFinishedLaunching { kill(a.processIdentifier, SIGSTOP); print(a.processIdentifier); exit(0) }
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(2) }
RunLoop.main.run()
