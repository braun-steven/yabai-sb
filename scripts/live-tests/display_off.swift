import CoreGraphics
import Foundation

// usage: display_off <stop file> <limit seconds> <off stages> <on stages>
// A stage list is `did@seconds,did@seconds`: the display id (the "id" of query --displays) and the time after the start of
// the list. It disables the displays of the off stages at those times, waits for the stop file (or the limit), and enables
// the displays of the on stages. Unlike mirroring, a disabled display is removed like an unplugged one: the callbacks
// report remove and add, and macOS destroys and recreates its spaces (doc/live-testing.md, "Display changes"). A real
// dock removes the main display and 0.2 s later the other one, and returns them in the other order with 3 s between:
// `display_off stop 60 2@0,3@0.2 3@0,2@3`. kCGConfigureForAppOnly reverts everything when the process exits. Prints
// `off <did>: <error>` and `on <did>: <error>` as it goes (0 is success), then `done`.
@_silgen_name("CGSConfigureDisplayEnabled")
func configureDisplayEnabled(_ config: CGDisplayConfigRef?, _ did: CGDirectDisplayID, _ on: Bool)
  -> CGError

struct Stage {
  var did: CGDirectDisplayID
  var delay: Double
}

func stages(_ text: String) -> [Stage] {
  text.split(separator: ",").map { stage in
    let parts = stage.split(separator: "@")
    return Stage(did: CGDirectDisplayID(parts[0])!, delay: parts.count > 1 ? Double(parts[1])! : 0)
  }
}

func configure(_ did: CGDirectDisplayID, enabled: Bool) -> CGError {
  var config: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }

  let error = configureDisplayEnabled(config, did, enabled)
  if error != .success {
    CGCancelDisplayConfiguration(config)
    return error
  }
  return CGCompleteDisplayConfiguration(config, .forAppOnly)
}

func run(_ list: [Stage], enabled: Bool) {
  let start = Date()
  for stage in list.sorted(by: { $0.delay < $1.delay }) {
    let wait = stage.delay - Date().timeIntervalSince(start)
    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
    print(
      "\(enabled ? "on" : "off") \(stage.did):", configure(stage.did, enabled: enabled).rawValue)
    fflush(stdout)
  }
}

let args = CommandLine.arguments
guard args.count == 5, let limit = Double(args[2]) else {
  fputs("usage: display_off <stop file> <limit seconds> <off stages> <on stages>\n", stderr)
  exit(2)
}

var active = [CGDirectDisplayID](repeating: 0, count: 16)
var count: UInt32 = 0
CGGetActiveDisplayList(16, &active, &count)
let off = stages(args[3])
if Set(active[..<Int(count)]).subtracting(off.map(\.did)).isEmpty {
  fputs("display_off: refusing to disable every display\n", stderr)
  exit(2)
}

run(off, enabled: false)
let deadline = Date().addingTimeInterval(limit)
while !FileManager.default.fileExists(atPath: args[1]) && Date() < deadline { usleep(100_000) }
run(stages(args[4]), enabled: true)
print("done")
fflush(stdout)
sleep(1)
