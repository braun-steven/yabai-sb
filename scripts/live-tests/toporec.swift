// usage: toporec <out.jsonl> <stop file> -> records until the stop file exists: every display reconfiguration callback,
// the sleep and space notifications, and every 100 ms a diff of the managed spaces and of the window to space map. It
// only reads. Build: swiftc -O -F /System/Library/PrivateFrameworks -framework SkyLight toporec.swift -o toporec
// NOTE: The CG callbacks need NSApplication.run(); RunLoop.main.run() delivers none.
import AppKit
import CoreGraphics
import Foundation

@_silgen_name("SLSMainConnectionID") func SLSMainConnectionID() -> Int32
@_silgen_name("SLSCopyManagedDisplaySpaces") func SLSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("SLSCopySpacesForWindows") func SLSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?

let cid = SLSMainConnectionID()
let out = CommandLine.arguments[1]
let stop = CommandLine.arguments[2]
FileManager.default.createFile(atPath: out, contents: nil)
let handle = FileHandle(forWritingAtPath: out)!
let lock = NSLock()
let t0 = Date()
func emit(_ kind: String, _ value: Any) {
  lock.lock(); defer { lock.unlock() }
  let line: [String: Any] = ["t": (Date().timeIntervalSince(t0) * 1000).rounded() / 1000, "k": kind, "v": value]
  if let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
    handle.write(d); handle.write("\n".data(using: .utf8)!)
  }
}
CGDisplayRegisterReconfigurationCallback({ did, flags, _ in
  var names: [String] = []
  if flags.contains(.beginConfigurationFlag) { names.append("begin") }
  if flags.contains(.addFlag) { names.append("add") }
  if flags.contains(.removeFlag) { names.append("remove") }
  if flags.contains(.movedFlag) { names.append("moved") }
  if flags.contains(.setMainFlag) { names.append("setMain") }
  if flags.contains(.setModeFlag) { names.append("setMode") }
  if flags.contains(.enabledFlag) { names.append("enabled") }
  if flags.contains(.disabledFlag) { names.append("disabled") }
  if flags.contains(.mirrorFlag) { names.append("mirror") }
  if flags.contains(.unMirrorFlag) { names.append("unmirror") }
  if flags.contains(.desktopShapeChangedFlag) { names.append("shape") }
  emit("cg", ["did": did, "flags": names])
}, nil)

let center = NSWorkspace.shared.notificationCenter
for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
  center.addObserver(forName: name, object: nil, queue: nil) { n in emit("ws", n.name.rawValue) }
}
NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { _ in emit("ws", "screenParameters") }

var lastSpaces = ""
var lastWindows: [String: [UInt64]] = [:]
func sample() {
  var displays: [[String: Any]] = []
  if let list = SLSCopyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]] {
    for d in list {
      let spaces = (d["Spaces"] as? [[String: Any]] ?? []).map { s -> [String: Any] in
        ["id": s["id64"] as? UInt64 ?? 0, "uuid": String((s["uuid"] as? String ?? "").prefix(8)), "type": s["type"] as? Int ?? -1]
      }
      let cur = (d["Current Space"] as? [String: Any])?["id64"] as? UInt64 ?? 0
      displays.append(["display": String((d["Display Identifier"] as? String ?? "?").prefix(8)), "current": cur, "spaces": spaces])
    }
  }
  if let data = try? JSONSerialization.data(withJSONObject: displays, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8), text != lastSpaces {
    lastSpaces = text
    emit("spaces", displays)
  }
  var now: [String: [UInt64]] = [:]
  var names: [String: String] = [:]
  if let infos = CGWindowListCopyWindowInfo([.optionAll], 0) as? [[String: Any]] {
    for w in infos {
      guard (w[kCGWindowLayer as String] as? Int) == 0, let id = w[kCGWindowNumber as String] as? UInt32 else { continue }
      let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
      if (b["Width"] ?? 0) < 100 || (b["Height"] ?? 0) < 100 { continue }
      let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
      if owner == "Window Server" || owner == "Dock" { continue }
      let arr = [NSNumber(value: id)] as CFArray
      let sp = (SLSCopySpacesForWindows(cid, 7, arr)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.uint64Value)
      if sp.isEmpty { continue }
      now["\(id)"] = sp.sorted()
      names["\(id)"] = owner
    }
  }
  var diff: [String: Any] = [:]
  for (k, v) in now where lastWindows[k] != v { diff[k] = ["app": names[k] ?? "?", "spaces": v] }
  for k in lastWindows.keys where now[k] == nil { diff[k] = NSNull() }
  if !diff.isEmpty { emit("windows", diff) }
  lastWindows = now
}
let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sample"))
timer.schedule(deadline: .now(), repeating: .milliseconds(100))
timer.setEventHandler {
  autoreleasepool { sample() }
  if FileManager.default.fileExists(atPath: stop) { exit(0) }
}
timer.resume()
emit("start", ["cid": cid])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
app.run()
