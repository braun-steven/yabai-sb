import YabaiCore

// MARK: Spaces

extension View {
  /// The space for `query --spaces`.
  func info(_ properties: Set<SpaceInfo.Key>) -> SpaceInfo {
    let sm = SpaceManager.shared
    var info = SpaceInfo(id: sid, properties: properties)

    if properties.contains(.uuid) { info.uuid = uuid.map { $0 as String } ?? "<unknown>" }
    if properties.contains(.index) { info.index = sid.missionControlIndex ?? 0 }
    if properties.contains(.label) { info.label = sm.labels.name(of: sid) ?? "" }
    if properties.contains(.type) { info.type = layout.rawValue }
    if properties.contains(.display) { info.display = sid.display.flatMap { $0.arrangement } ?? 0 }
    if properties.contains(.pinnedDisplay) { info.pinnedDisplay = sm.pinnedArrangement(of: sid) }
    if properties.contains(.windows) { info.windows = sid.windows(includingMinimized: true) ?? [] }
    if properties.contains(.firstWindow) {
      info.firstWindow = tree?.firstLeaf?.focusedDescendant.windowID
    }
    if properties.contains(.lastWindow) { info.lastWindow = tree?.lastLeaf?.windowID }
    if properties.contains(.hasFocus) { info.hasFocus = sid == sm.currentSpaceID }
    if properties.contains(.isVisible) { info.isVisible = sid.isVisible }
    if properties.contains(.isFullscreen) { info.isFullscreen = sid.isFullscreen }

    return info
  }
}

extension SpaceManager {
  // NOTE: Spaces that have no view are left out.
  /// The spaces of the list for `query --spaces`.
  func spaceInfos(_ spaceList: [SpaceID], _ properties: Set<SpaceInfo.Key>) -> [SpaceInfo] {
    spaceList.compactMap { queryView(for: $0)?.info(properties) }
  }
}
