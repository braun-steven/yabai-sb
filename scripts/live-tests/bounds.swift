import CoreGraphics
import Foundation
// usage: bounds wid...       -> prints "wid x y w h" from the window server
//        bounds order wid... -> prints the on-screen windows among wid, front to back
var args = Array(CommandLine.arguments.dropFirst())
let order = args.first == "order"
if order { args.removeFirst() }
let ids = Set(args.compactMap { UInt32($0) })
let list = CGWindowListCopyWindowInfo(order ? [.optionOnScreenOnly] : [.optionAll], kCGNullWindowID) as! [[String: Any]]
for info in list {
    guard let wid = info[kCGWindowNumber as String] as? UInt32, ids.contains(wid) else { continue }
    if order { print(wid); continue }
    guard let b = info[kCGWindowBounds as String] as? [String: Double] else { continue }
    print(wid, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
}
