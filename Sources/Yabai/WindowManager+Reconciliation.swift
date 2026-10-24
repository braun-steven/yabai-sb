import YabaiCore

extension WindowManager {
  /// The windows of the space without minimized windows.
  private func windows(onSpace sid: SpaceID) -> [WindowID]? {
    sid.windows(includingMinimized: false)
  }

  // NOTE: Internal, not private, so that tests can reconcile a view against a window list without the window server.
  func validateWindows(on owner: View, against windowList: [WindowID]) {
    let onSpace = Set(windowList)

    for windowID in owner.windowIDs where !onSpace.contains(windowID) {
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

  private func checkForWindows(on owner: View, in windowList: [WindowID]) {
    for windowID in windowList {
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
  }

  // NOTE: Internal so tests can exercise reconciliation with an explicit window list, without querying the window
  // server for the space's current windows.
  func reconcileWindows(on owner: View, against windowList: [WindowID]) {
    guard owner.layout != .float else { return }

    validateWindows(on: owner, against: windowList)
    checkForWindows(on: owner, in: windowList)
  }

  func validateAndCheckForWindows(on sid: SpaceID) {
    let owner = SpaceManager.shared.view(for: sid)
    if owner.layout == .float { return }

    let windowList = windows(onSpace: sid) ?? []
    reconcileWindows(on: owner, against: windowList)

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
        if owner.layout != .float {
          checkForWindows(on: owner, in: windowList)
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
