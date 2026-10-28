import CPrivate
import CoreGraphics
import Foundation
import YabaiCore

// NOTE: A view is the layout state of one space: its tree, its area and its padding and gap.

/// The layout of a space, named as in `config layout` and `query --spaces`. A view of the default type follows the
/// global layout.
enum ViewType: String, CaseIterable, Sendable {
  case `default`
  case float
  case tree
}

/// The settings a space set for itself with `config --space`: the global config no longer changes them for its view.
struct ViewOverrides: OptionSet, Sendable {
  let rawValue: UInt32

  static let layout = ViewOverrides(rawValue: 1 << 0)
  static let topPadding = ViewOverrides(rawValue: 1 << 1)
  static let bottomPadding = ViewOverrides(rawValue: 1 << 2)
  static let leftPadding = ViewOverrides(rawValue: 1 << 3)
  static let rightPadding = ViewOverrides(rawValue: 1 << 4)
  static let windowGap = ViewOverrides(rawValue: 1 << 5)
  static let autoPadding = ViewOverrides(rawValue: 1 << 6)
}

/// A padding or the gap of a view, and of the space manager defaults that views without their own value follow.
enum ViewSpacing: CaseIterable, Sendable {
  case topPadding
  case bottomPadding
  case leftPadding
  case rightPadding
  case windowGap

  /// The value in a view.
  @WM var view: ReferenceWritableKeyPath<View, Int> {
    switch self {
    case .topPadding: \.topPadding
    case .bottomPadding: \.bottomPadding
    case .leftPadding: \.leftPadding
    case .rightPadding: \.rightPadding
    case .windowGap: \.windowGap
    }
  }

  /// The override a view records once it has its own value.
  var override: ViewOverrides {
    switch self {
    case .topPadding: .topPadding
    case .bottomPadding: .bottomPadding
    case .leftPadding: .leftPadding
    case .rightPadding: .rightPadding
    case .windowGap: .windowGap
    }
  }
}

/// isValid is false once the area of the view must be recomputed, isDirty while its tree has not been laid out since it
/// changed, and isUnpadded while auto padding removes its padding. layoutFrame is the display frame of the last update:
/// a view whose display frame is another one now is stale (`isStale(for:)`).
@WM final class View {
  var uuid: CFString?
  var sid: SpaceID
  var area = Area.zero
  var tree: Con?
  /// The trees before the last tree commands of this space, for space --undo.
  var history = TreeHistory()
  var insertionPoint: WindowID?
  var layout = ViewType.default
  var topPadding: Int = 0
  var bottomPadding: Int = 0
  var leftPadding: Int = 0
  var rightPadding: Int = 0
  var windowGap: Int = 0
  var autoPadding = false
  var overrides: ViewOverrides = []
  var isPaddingEnabled = false
  var isGapEnabled = false
  var isValid = false
  var isDirty = false
  var isUnpadded = false
  var layoutFrame: CGRect?

  init(sid: SpaceID) {
    self.sid = sid
  }

  var windowGapValue: Int {
    ViewArea.windowGap(gapEnabled: isGapEnabled, windowGap: windowGap)
  }

  var isInvalid: Bool { !isValid }

  /// Applies the tree to the windows.
  func flush() {
    updateSplitDragLayout()
    if Headless.isEnabled {
      flushHeadless()
    } else if sid.isVisible {
      flushTree()
      isDirty = false
    } else {
      isDirty = true
    }
  }

  func rootArea(in frame: CGRect) -> Area {
    let root = ViewArea.rootArea(
      Area(frame),
      paddingEnabled: isPaddingEnabled,
      unpadded: isUnpadded,
      top: topPadding,
      bottom: bottomPadding,
      left: leftPadding,
      right: rightPadding)

    return Area(x: root.x, y: root.y, w: root.w, h: root.h)
  }

  // NOTE: Re-layout the view if the tiled window count crossed the auto padding threshold. Returns true if it did,
  // in which case the whole tree must be flushed.
  @discardableResult
  func updateAutoPadding() -> Bool {
    let unpadded = Self.autoPaddingApplies(
      layout: layout, autoPadding: autoPadding, tiledCount: tiledCount)
    if unpadded == isUnpadded { return false }

    updateWithAutoPadding(unpadded)
    return true
  }

  func update() {
    updateWithAutoPadding(
      Self.autoPaddingApplies(layout: layout, autoPadding: autoPadding, tiledCount: tiledCount))
  }

  func updateAndFlush() {
    update()
    flush()
  }

  /// The frame that `update` lays the view out in: its display's (`Headless.displayFrame` in headless mode); nil while
  /// the window server reports no display for the space.
  var displayFrame: CGRect? {
    if Headless.isEnabled { return Headless.displayFrame }
    return sid.display?.constrainedBounds(ignoringExternalBar: false)
  }

  /// Whether the view must be updated to be laid out in `frame`, its display frame now: it is invalid, or its last
  /// update was for another frame (its space moved to another display, or the display's frame changed).
  func isStale(for frame: CGRect) -> Bool {
    isInvalid || layoutFrame != frame
  }

  /// Whether the view must be updated for the display the window server has for its space now (`isStale(for:)`).
  var needsUpdate: Bool {
    guard let frame = displayFrame else { return false }
    return isStale(for: frame)
  }

  //
  // NOTE: The window server moves the windows of a space that moves to another display with it, and reports those moves
  // after the space is on its new display (the window moved and resized events of the space's windows). A stale view is
  // updated before that flush, so the windows are laid out for the new display instead of being put back where the tree
  // had them on the old one.
  //

  /// Flushes the view after the window server moved or resized one of its windows; a stale view is updated first.
  func flushAfterWindowChange() {
    if needsUpdate { update() }
    flush()
  }

  /// What a refresh pass of the spaces does with a view (`refreshStep(frame:isVisible:)`).
  enum RefreshStep: Equatable {
    case none
    /// Flush the tree: the view is shown and dirty.
    case flush
    /// Update and flush: the view is stale. A hidden one keeps its windows and stays dirty until it is shown.
    case update
  }

  /// The step of a refresh pass for the view, given its display frame now (`frame`, nil without a display) and whether
  /// its display shows it. A float view is never laid out.
  func refreshStep(frame: CGRect?, isVisible: Bool) -> RefreshStep {
    guard layout != .float, let frame else { return .none }
    if isStale(for: frame) { return .update }
    return isVisible && isDirty ? .flush : .none
  }

  func clear() {
    insertionPoint = nil
    clearTree()
    update()
  }

  func destroy() {
    clearTree()
    uuid = nil
  }

  private func updateWithAutoPadding(_ unpadded: Bool) {
    isUnpadded = unpadded

    guard let frame = displayFrame else { return }
    area = rootArea(in: frame)
    layoutFrame = frame

    updateTree()
    isValid = true
    isDirty = true
  }

  static func autoPaddingApplies(layout: ViewType, autoPadding: Bool, tiledCount: Int) -> Bool {
    ViewArea.autoPaddingApplies(
      isTree: layout == .tree, autoPadding: autoPadding, tiledCount: tiledCount)
  }

  static func create(sid: SpaceID) -> View {
    let target = View(sid: sid)

    target.uuid = SLS.spaceNameObject(SLS.connection, sid)
    target.isPaddingEnabled = true
    target.isGapEnabled = true

    if target.sid.isUser {
      let defaults = Config.current.space

      target.layout = defaults.layout
      target.topPadding = defaults.topPadding
      target.bottomPadding = defaults.bottomPadding
      target.leftPadding = defaults.leftPadding
      target.rightPadding = defaults.rightPadding
      target.windowGap = defaults.windowGap
      target.autoPadding = defaults.autoPadding
      target.update()
    } else {
      target.layout = .float
    }

    return target
  }
}

extension View: Equatable {
  nonisolated static func == (a: View, b: View) -> Bool { a === b }
}
