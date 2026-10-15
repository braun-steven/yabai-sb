import CoreGraphics
import Foundation
// usage: mirror <mirrored did> <master did> <stop file> -> mirrors one display onto the other, which removes it for
// yabai like an unplug, until the stop file exists (at most 240 s), then unmirrors (a replug). kCGConfigureForAppOnly
// also reverts the mirror when the process exits. Display ids are the "id" of query --displays.
let args = CommandLine.arguments
let mirrored = CGDirectDisplayID(args[1])!, master = CGDirectDisplayID(args[2])!, stop = args[3]

func configure(_ to: CGDirectDisplayID) -> CGError {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }
    let e = CGConfigureDisplayMirrorOfDisplay(config, mirrored, to)
    if e != .success { CGCancelDisplayConfiguration(config); return e }
    return CGCompleteDisplayConfiguration(config, .forAppOnly)
}

print("mirror:", configure(master).rawValue); fflush(stdout)
let deadline = Date().addingTimeInterval(240)
while !FileManager.default.fileExists(atPath: stop) && Date() < deadline { usleep(200_000) }
print("unmirror:", configure(kCGNullDirectDisplay).rawValue); fflush(stdout)
sleep(1)
