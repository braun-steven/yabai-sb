import CPrivate
import Foundation
import OrderedCollections
import YabaiCore

//
// NOTE: Scratchpads are labeled windows that are floated and toggled between hidden (ordered out)
// and shown on the active space, using the scratchpad_* options. WindowManager owns their list.
//

extension WindowManager {
  func toggleScratchpad(withLabel label: String) -> Bool {
    guard let target = scratchpads[label] else { return false }
    return toggleScratchpad(target)
  }

  func setScratchpadLayers() {
    for target in scratchpads.values {
      target.adjustLayer(to: Config.current.scratchpad.below ? .below : .normal)
    }
  }

  private func hideOtherScratchpadWindows(except target: Window) {
    for other in scratchpads.values where other != target {
      if SLS.windowIsOrderedIn(SLS.connection, other.id) {
        ScriptingAddition.shared.orderWindow(other.id, 0, relativeTo: nil)
      }
    }
  }

  private func applyScratchpadGrid(to target: Window) {
    let grid = Config.current.scratchpad.grid
    if grid.rows == 0 || grid.columns == 0 { return }

    try? applyGrid(grid, to: target)
  }

  private func hideScratchpad(_ target: Window, on spaceID: SpaceID) {
    if let next = window(on: spaceID, byRank: 1, excluding: target.id) {
      focusWithRaise(next)
    } else {
      SLS.setFrontProcess(ProcessManager.shared.finderPSN, window: nil, mode: .noWindows)
    }

    ScriptingAddition.shared.orderWindow(target.id, 0, relativeTo: nil)
  }

  private func showScratchpad(
    _ target: Window,
    on spaceID: SpaceID,
    movingToSpace: Bool,
    applyingGrid: Bool
  ) {
    if movingToSpace {
      spaceID.moveWindow(target)
      _ = spaceID.waitForWindow(target.id, timeoutMS: 200)
    }

    if applyingGrid { applyScratchpadGrid(to: target) }
    ScriptingAddition.shared.orderWindow(target.id, 1, relativeTo: nil)
    focusWithRaise(target)
  }

  func toggleScratchpad(_ target: Window) -> Bool {
    guard let spaceID = SpaceID.active else { return false }

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    let visibleSpace = target.id.space == spaceID || target.id.isSticky

    let orderedIn = SLS.windowIsOrderedIn(SLS.connection, target.id)

    var shown = true

    if visibleSpace && orderedIn {
      if Config.current.scratchpad.raise && focus.focused != target.id && !target.isMinimized
        && !target.application.isHidden
      {
        focusWithRaise(target)
      } else {
        hideScratchpad(target, on: spaceID)
        shown = false
      }
    } else {
      showScratchpad(target, on: spaceID, movingToSpace: !visibleSpace, applyingGrid: !orderedIn)
    }

    if shown && Config.current.scratchpad.exclusive {
      hideOtherScratchpadWindows(except: target)
    }

    Border.refreshSpace(of: target)

    return true
  }

  func setScratchpad(for target: Window, label: String) -> Bool {
    if scratchpads[label] != nil { return false }

    _ = removeScratchpad(from: target, unfloat: false)
    scratchpads[label] = target
    target.scratchpad = label
    makeWindowFloating(target, shouldFloat: true, force: false)

    //
    // NOTE: Floating puts the window on the normal sub-layer, above
    // tiled windows; scratchpad.below moves it to their sub-layer.
    //

    if Config.current.scratchpad.below { target.adjustLayer(to: .below) }

    return true
  }

  //
  // NOTE: A window that stops being a scratchpad is brought to the active space and shown,
  // without the scratchpad_* options, which only apply to toggling by label.
  //

  private func releaseScratchpad(_ target: Window) {
    if let spaceID = SpaceID.active {
      showScratchpad(target, on: spaceID, movingToSpace: true, applyingGrid: false)
      Border.refreshSpace(of: target)
    }

    if Config.current.scratchpad.below { target.adjustLayer(to: .normal) }
    makeWindowFloating(target, shouldFloat: false, force: false)
  }

  @discardableResult
  func removeScratchpad(from target: Window, unfloat: Bool) -> Bool {
    guard let label = target.scratchpad, scratchpads[label] == target else { return false }

    target.scratchpad = nil
    scratchpads[label] = nil

    if unfloat { releaseScratchpad(target) }

    return true
  }

  func recoverScratchpadWindows() {
    guard let windowList = existingApplicationWindowList(for: nil) else { return }

    if ScriptingAddition.shared.orderIn(windowList) {
      _ = SpaceManager.shared.refreshApplicationWindows()
    }
  }
}
