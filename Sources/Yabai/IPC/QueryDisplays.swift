import CoreGraphics
import YabaiCore

// MARK: Displays

extension DisplayID {
  /// The display for `query --displays`.
  @WM func info(_ properties: Set<DisplayInfo.Key>) -> DisplayInfo {
    let dm = DisplayManager.shared
    var info = DisplayInfo(id: self, properties: properties)

    if properties.contains(.uuid) { info.uuid = uuid ?? "<unknown>" }
    if properties.contains(.index) { info.index = arrangement ?? 0 }
    if properties.contains(.label) { info.label = dm.labels.name(of: self) ?? "" }
    if properties.contains(.frame) { info.frame = QueryFrame(CGDisplayBounds(rawValue)) }
    if properties.contains(.spaces) { info.spaces = spaceIndices }
    if properties.contains(.hasFocus) { info.hasFocus = self == dm.currentDisplayID }

    return info
  }

  // NOTE: The Mission Control indices of the spaces of a display.
  @WM private var spaceIndices: [Int] {
    guard let spaceList = spaces, let first = spaceList.first?.missionControlIndex else {
      return []
    }
    return (0..<spaceList.count).map { first + $0 }
  }
}
