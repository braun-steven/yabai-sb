import CoreGraphics
import Foundation

// usage: mouse move|click|down|up x y | mouse sweep x0 y0 x1 y1 steps | mouse altdrag x0 y0 x1 y1 steps | mouse trusted
let a = CommandLine.arguments
// NOTE: CGEvent.post silently drops events when posting is denied, including inside a command sandbox.
if a[1] != "trusted" && !CGPreflightPostEventAccess() {
  FileHandle.standardError.write(
    Data(
      "mouse: event posting denied; run outside the command sandbox with Accessibility permission\n"
        .utf8))
  exit(EXIT_FAILURE)
}
func post(_ type: CGEventType, _ p: CGPoint, _ flags: CGEventFlags = []) {
  let e = CGEvent(
    mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
  e.flags = flags
  e.post(tap: .cghidEventTap)
}
func d(_ i: Int) -> Double { Double(a[i])! }
switch a[1] {
case "trusted":
  print(CGPreflightPostEventAccess())
case "move":
  post(.mouseMoved, CGPoint(x: d(2), y: d(3)))
case "click", "down", "up":
  let point = CGPoint(x: d(2), y: d(3))
  post(.mouseMoved, point)
  usleep(20000)
  if a[1] != "up" { post(.leftMouseDown, point) }
  if a[1] == "click" { usleep(50000) }
  if a[1] != "down" { post(.leftMouseUp, point) }
case "sweep":
  let n = Int(a[6])!
  for i in 0...n {
    let t = Double(i) / Double(n)
    post(.mouseMoved, CGPoint(x: d(2) + (d(4) - d(2)) * t, y: d(3) + (d(5) - d(3)) * t))
    usleep(2000)
  }
case "altdrag":
  let n = Int(a[6])!
  let p0 = CGPoint(x: d(2), y: d(3))
  post(.mouseMoved, p0, .maskAlternate)
  usleep(20000)
  post(.leftMouseDown, p0, .maskAlternate)
  usleep(20000)
  for i in 1...n {
    let t = Double(i) / Double(n)
    post(
      .leftMouseDragged, CGPoint(x: d(2) + (d(4) - d(2)) * t, y: d(3) + (d(5) - d(3)) * t),
      .maskAlternate)
    usleep(1000)
  }
  usleep(50000)
  post(.leftMouseUp, CGPoint(x: d(4), y: d(5)), .maskAlternate)
default: break
}
