import CoreGraphics
import Foundation

// Read-only check for visible, untabbed windows with borders enabled (hide_single off).
// Compile: swiftc -O -warnings-as-errors border_geometry.swift -o /tmp/yabai-border-geometry
// Usage: /tmp/yabai-border-geometry <border width> <window id>...
let arguments = Array(CommandLine.arguments.dropFirst())
guard let first = arguments.first, let width = Double(first), width > 0,
      arguments.count > 1, arguments.dropFirst().allSatisfy({ UInt32($0) != nil }) else {
    print("usage: border_geometry <border width> <window id>...")
    exit(2)
}
let ids = Set(arguments.dropFirst().compactMap(UInt32.init))
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] else {
    print("FAIL: cannot read on-screen windows")
    exit(1)
}

func frame(_ info: [String: Any]) -> CGRect
{
    let bounds = info[kCGWindowBounds as String] as! [String: Double]
    return CGRect(x: bounds["X"]!, y: bounds["Y"]!, width: bounds["Width"]!, height: bounds["Height"]!)
}

var seen: Set<UInt32> = []
var failed = false
for (index, info) in windows.enumerated() {
    let wid = info[kCGWindowNumber as String] as! UInt32
    guard ids.contains(wid) else { continue }
    seen.insert(wid)
    let bounds = frame(info)
    // Each ring's four windows must be ordered immediately below its owner.
    var edges: [CGRect] = []
    for candidate in windows.dropFirst(index + 1) {
        guard candidate[kCGWindowOwnerName as String] as? String == "yabai" else { break }
        edges.append(frame(candidate))
    }
    let ring = edges.reduce(CGRect.null) { $0.union($1) }
    let expected = bounds.insetBy(dx: -width, dy: -width)
    let ok = edges.count == 4 && ring == expected
    print("\(ok ? "PASS" : "FAIL") \(wid) window=\(bounds) ring=\(ring) edges=\(edges)")
    failed = failed || !ok
}
for wid in ids.subtracting(seen).sorted() {
    print("FAIL \(wid): window is not on screen")
    failed = true
}
exit(failed ? 1 : 0)
