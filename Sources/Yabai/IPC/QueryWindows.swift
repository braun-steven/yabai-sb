import AppKit
import CPrivate
import CoreGraphics
import Darwin
import YabaiCore

// MARK: Windows

/// `window_layer`: the name of a window level.
private func layerName(_ level: Int32) -> String {
  if level == CGWindowLevelForKey(.backstopMenu) { return WindowLayer.below.rawValue }
  if level == CGWindowLevelForKey(.normalWindow) { return WindowLayer.normal.rawValue }
  if level == CGWindowLevelForKey(.floatingWindow) { return WindowLayer.above.rawValue }
  return "unknown"
}

extension WindowInfo {
  // NOTE: Without a space (or a display of it), the printed values are 0, as the arrangement and index of no display and no space.
  @WM fileprivate mutating func setSpace(_ sid: SpaceID?) {
    if properties.contains(.display) {
      display = sid.flatMap { $0.display }.flatMap { $0.arrangement } ?? 0
    }
    if properties.contains(.space) { space = sid.flatMap { $0.missionControlIndex } ?? 0 }
  }

  fileprivate mutating func setLevels(_ wid: WindowID) {
    if !properties.isDisjoint(with: [.level, .layer]) { level = wid.level }
    if !properties.isDisjoint(with: [.subLevel, .subLayer]) { subLevel = wid.subLevel }
    if properties.contains(.layer) { layer = layerName(level) }
    if properties.contains(.subLayer) { subLayer = layerName(subLevel) }
    if properties.contains(.hasShadow) { hasShadow = wid.hasShadow }
  }

  /// The split, stack index and zoom of the container of a managed window.
  @WM mutating func setTree(_ node: Con?) {
    guard let node else { return }

    if let parent = node.parent {
      if parent.layout == .splitH { split = .y }
      if parent.layout == .splitV { split = .x }
    }

    var tab = node
    while let parent = tab.parent, parent.layout != .tabbed { tab = parent }
    stackIndex = tab.index.map { $0 + 1 } ?? 0

    hasParentZoom = node.zoom == .parent
    hasFullscreenZoom = node.zoom == .fullscreen
  }
}

extension Window {
  /// The window for `query --windows`.
  func info(_ properties: Set<WindowInfo.Key>) -> WindowInfo {
    let wm = WindowManager.shared
    let application = self.application!

    var info = WindowInfo(id: id, properties: properties)
    info.pid = application.pid
    info.app = application.name
    info.scratchpad = scratchpad ?? ""
    info.label = wm.labels.name(of: id)
    info.frame = frame
    info.isRoot = isRoot
    info.hasFocus = id == wm.focus.focused
    info.hasAXReference = true
    info.isFullscreen = isFullscreen
    info.isMinimized = isMinimized
    info.isHidden = application.isHidden
    info.isFloating = isFloating
    info.isGrabbed = self == MouseState.shared.window

    if properties.contains(.title) { info.title = ax.title ?? "" }
    if properties.contains(.role) { info.role = ax.role ?? "" }
    if properties.contains(.subrole) { info.subrole = ax.subrole ?? "" }
    if properties.contains(.canMove) { info.canMove = canMove }
    if properties.contains(.canResize) { info.canResize = canResize }
    info.setLevels(id)

    var sid: SpaceID?
    if !properties.isDisjoint(with: [.display, .space, .isVisible]) {
      sid = id.space
      info.setSpace(sid)
    }

    if !properties.isDisjoint(with: [.splitType, .stackIndex, .hasParentZoom, .hasFullscreenZoom]) {
      info.setTree(wm.managedView(for: self)?.findWindow(id))
    }

    if !properties.isDisjoint(with: [.isVisible, .isSticky]) {
      info.isSticky = isSticky || id.isSticky
    }

    if properties.contains(.isVisible) {
      info.isVisible =
        SLS.windowIsOrderedIn(SLS.connection, id) && !info.isMinimized && !info.isHidden
        && (info.isSticky || (sid.map { $0.isVisible } ?? false))
    }

    return info
  }
}

extension WindowID {
  // NOTE: Windows that yabai has no AX reference for only report what the window server knows.
  /// A window yabai does not track, for `query --windows`.
  @WM func info(_ properties: Set<WindowInfo.Key>) -> WindowInfo {
    var info = WindowInfo(id: self, properties: properties)
    info.app = ""
    info.scratchpad = ""
    info.role = ""
    info.subrole = ""

    if !properties.isDisjoint(with: [.pid, .app]) {
      if let owner = SLS.windowOwner(SLS.connection, self), let pid = SLS.connectionPID(owner) {
        info.pid = pid
      }

      if properties.contains(.app) {
        // NOTE: PROC_PIDPATHINFO_MAXSIZE, which Swift does not import
        var name = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_name(info.pid, &name, UInt32(name.count)) > 0 {
          info.app = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        }
      }
    }

    if properties.contains(.title) { info.title = SLS.windowTitle(SLS.connection, self) ?? "" }
    if properties.contains(.frame) { info.frame = SLS.windowBounds(SLS.connection, self) ?? .zero }
    if properties.contains(.rootWindow) { info.isRoot = parent == nil }
    if properties.contains(.isSticky) { info.isSticky = isSticky }
    info.setLevels(self)

    if !properties.isDisjoint(with: [.display, .space, .isFullscreen]) {
      let sid = space
      info.setSpace(sid)
      if properties.contains(.isFullscreen) {
        info.isFullscreen = sid.map { $0.isFullscreen } ?? false
      }
    }

    return info
  }
}

extension WindowManager {
  /// The windows of the spaces for `query --windows`, tracked or not.
  func windowInfos(on spaceList: [SpaceID], _ properties: Set<WindowInfo.Key>) -> [WindowInfo] {
    let windowList = SpaceID.windows(on: spaceList, connection: nil, includingMinimized: true) ?? []
    return windowList.map { wid in window(for: wid)?.info(properties) ?? wid.info(properties) }
  }
}
