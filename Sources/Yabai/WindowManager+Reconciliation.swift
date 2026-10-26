import YabaiCore

extension WindowManager {
  /// The windows of the space without minimized windows.
  private func windows(onSpace sid: SpaceID) -> [WindowID]? {
    sid.windows(includingMinimized: false)
  }

  //
  // NOTE: Reconciliation leaves the window of a mouse drag (`dragged`, `MouseState.draggedWindowID`) in its tree until
  // the drop, like sway's seatop_move_tiling, which re-arranges nothing before the drop. The window server puts a
  // dragged window on the space of the display it is over, and the display change that a drag across displays causes
  // reconciles the space there (`displayChanged`): it took the window out of the source tree before the drop, so the
  // drop found it in the target view and missed every drop action (#2843).
  //

  // NOTE: Internal, not private, so that tests can reconcile a view against a window list without the window server.
  func validateWindows(on owner: View, against windowList: [WindowID], dragged: WindowID? = nil) {
    let onSpace = Set(windowList)

    for windowID in owner.windowIDs where !onSpace.contains(windowID) && windowID != dragged {
      guard let target = window(for: windowID) else { continue }

      //
      // @cleanup
      //
      // :AXBatching
      //
      // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
      // making sure that each window is only moved and resized a single time, when the final layout has been computed.
      // This is necessary to make sure that we do not call the AX API for each modification to the tree.
      //

      unmanage(target, from: owner, options: .purify)

      owner.isDirty = true
    }
  }

  /// Adds the windows of windowList that owner does not manage to owner, taking them out of the tiled view that manages
  /// them. Returns those source views: they are dirty until the caller flushes them.
  @discardableResult
  private func checkForWindows(on owner: View, in windowList: [WindowID], dragged: WindowID?)
    -> [View]
  {
    var sources: [View] = []
    for windowID in windowList where windowID != dragged {
      guard let target = window(for: windowID), target.shouldBeManaged else { continue }

      let existingView = managedView(for: target)
      if let existingView, existingView.layout != .float, existingView != owner {

        //
        // @cleanup
        //
        // :AXBatching
        //
        // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
        // making sure that each window is only moved and resized a single time, when the final layout has been computed.
        // This is necessary to make sure that we do not call the AX API for each modification to the tree.
        //

        unmanage(target, from: existingView, options: .purify)
        existingView.isDirty = true
        if !sources.contains(existingView) { sources.append(existingView) }
      }

      if existingView == nil || (existingView!.layout != .float && existingView != owner) {

        //
        // @cleanup
        //
        // :AXBatching
        //
        // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
        // making sure that each window is only moved and resized a single time, when the final layout has been computed.
        // This is necessary to make sure that we do not call the AX API for each modification to the tree.
        //

        owner.add(target, insertionPoint: nil)
        target.adjustLayer(to: .below)
        addManagedWindow(target, to: owner)
        owner.isDirty = true
      }
    }
    return sources
  }

  // NOTE: Internal so tests can exercise reconciliation with an explicit window list, without querying the window
  // server for the space's current windows. Returns the other views that windows were taken from.
  @discardableResult
  func reconcileWindows(on owner: View, against windowList: [WindowID], dragged: WindowID? = nil)
    -> [View]
  {
    guard owner.layout != .float else { return [] }

    validateWindows(on: owner, against: windowList, dragged: dragged)
    return checkForWindows(on: owner, in: windowList, dragged: dragged)
  }

  func validateAndCheckForWindows(on sid: SpaceID) {
    let owner = SpaceManager.shared.view(for: sid)
    if owner.layout == .float { return }

    let windowList = windows(onSpace: sid) ?? []
    reconcileAndFlush(owner, against: windowList, dragged: MouseState.shared.draggedWindowID)
  }

  /// Reconciles owner with windowList (`reconcileWindows`), then flushes owner when it is shown and the views that
  /// windows were taken from.
  // NOTE: Internal so tests can reconcile and flush against an explicit window list.
  func reconcileAndFlush(_ owner: View, against windowList: [WindowID], dragged: WindowID?) {
    let sources = reconcileWindows(on: owner, against: windowList, dragged: dragged)

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    if owner.sid.isVisible && owner.isDirty {
      owner.flush()
    }

    //
    // NOTE: A view that a window was taken from re-tiles its tree without the window, so it is flushed too (a hidden one
    // stays dirty until it is shown). Only the owner was flushed before: a window that moved to another display left the
    // frames of the source display stale, with a gap where the window was (#2843).
    //

    for source in sources where source.isDirty {
      source.flush()
    }
  }

  func correctForMissionControlChanges() {
    let displays = DisplayID.all

    withoutAnimations {
      for did in displays {
        guard let spaceList = did.spaces else { continue }

        let sid = did.currentSpace
        for space in spaceList {
          if let sid, space == sid {
            validateAndCheckForWindows(on: sid)
          } else {
            SpaceManager.shared.markViewInvalid(for: space)
          }
        }
      }
    }
  }

  func handleDisplayAddAndRemove(_ did: DisplayID) {
    guard let spaceList = did.spaces else { return }

    for space in spaceList where space.isUser {
      if let windowList = windows(onSpace: space) {
        let owner = SpaceManager.shared.view(for: space)
        // NOTE: The views that windows were taken from are flushed by the refresh pass after the display change
        // (`SpaceManager.scheduleDisplaySpacesRefresh`), which flushes the dirty views that are shown.
        if owner.layout != .float {
          checkForWindows(
            on: owner, in: windowList, dragged: MouseState.shared.draggedWindowID)
        }
      }
      break
    }

    let sid = did.currentSpace
    for space in spaceList {
      if let sid, space == sid {
        SpaceManager.shared.refreshView(for: sid)
      } else {
        SpaceManager.shared.markViewInvalid(for: space)
      }
    }
  }
}
