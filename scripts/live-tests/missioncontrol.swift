import CoreGraphics
import Foundation

// usage: missioncontrol state|open|close|toggle
//
// NOTE: Posts the user's Mission Control shortcut (symbolic hotkey 32) and waits up to 2 s for the Dock's overlay (a
// Dock window at layer 20 the size of a display, as `MissionControl.overlayIsShown` checks). Prints the final state;
// exits with failure when open or close did not reach it. Needs event posting access (`mouse trusted`).
let a = CommandLine.arguments

func isShown() -> Bool {
  let list =
    CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
  return list.contains { w in
    let width = (w[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double ?? 0
    return (w[kCGWindowOwnerName as String] as? String) == "Dock"
      && (w[kCGWindowLayer as String] as? Int) == 20
      && width >= 1000
  }
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("missioncontrol: \(message)\n".utf8))
  exit(EXIT_FAILURE)
}

/// The key code and modifier flags of symbolic hotkey 32, or nil when it is disabled.
func hotkey() -> (CGKeyCode, CGEventFlags)? {
  let all = CFPreferencesCopyAppValue(
    "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
  guard let entry = (all as? [String: Any])?["32"] as? [String: Any],
    (entry["enabled"] as? Int) == 1,
    let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int],
    parameters.count == 3
  else { return nil }
  var flags = CGEventFlags(rawValue: UInt64(parameters[2]))
  // NOTE: Function keys from a real keyboard carry the fn flag, and the hotkey does not fire without it.
  let functionKeys: Set<Int> = [
    122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 160,
  ]
  if functionKeys.contains(parameters[1]) { flags.insert(.maskSecondaryFn) }
  return (CGKeyCode(parameters[1]), flags)
}

func press() {
  guard CGPreflightPostEventAccess() else {
    fail("event posting denied; run outside the command sandbox")
  }
  guard let (code, flags) = hotkey() else {
    fail("the Mission Control shortcut (symbolic hotkey 32) is disabled")
  }
  for down in [true, false] {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(30000)
  }
}

func wait(for shown: Bool) -> Bool {
  for _ in 0..<40 {
    if isShown() == shown { return true }
    usleep(50000)
  }
  return false
}

switch a.count > 1 ? a[1] : "" {
case "state":
  print(isShown() ? "open" : "closed")
case "open", "close":
  let target = a[1] == "open"
  if isShown() != target {
    press()
    if !wait(for: target) { fail("Mission Control did not \(a[1])") }
  }
  print(target ? "open" : "closed")
case "toggle":
  let target = !isShown()
  press()
  _ = wait(for: target)
  print(isShown() ? "open" : "closed")
default:
  fail("usage: missioncontrol state|open|close|toggle")
}
