import YabaiCore

extension WindowManager
{
    /// The windows of the space without minimized windows.
    private func windows(onSpace sid: SpaceID) -> [WindowID]?
    {
        sid.windows(includingMinimized: false)
    }

    private func validateWindows(on owner: View, against windowList: [WindowID])
    {
        let viewWindowList = owner.windowIDs

        for i in 0..<viewWindowList.count {
            if windowList.contains(viewWindowList[i]) { continue }

            guard let target = window(for: viewWindowList[i]) else { continue }

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            owner.remove(target)
            target.adjustLayer(to: .normal)
            removeManagedWindow(target.id)
            purifyWindow(target)

            owner.isDirty = true
        }
    }

    private func checkForWindows(on owner: View, in windowList: [WindowID])
    {
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

                existingView.remove(target)
                target.adjustLayer(to: .normal)
                removeManagedWindow(target.id)
                purifyWindow(target)
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

    func validateAndCheckForWindows(on sid: SpaceID)
    {
        let owner = space_manager_find_view(SpaceManager.shared, sid)
        if owner.layout == .float { return }

        let windowList = windows(onSpace: sid) ?? []
        validateWindows(on: owner, against: windowList)
        checkForWindows(on: owner, in: windowList)

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

    func correctForMissionControlChanges()
    {
        let displays = DisplayID.all

        let animationDuration = windowAnimationDuration
        windowAnimationDuration = 0.0

        for did in displays {
            guard let spaceList = did.spaces else { continue }

            let sid = did.currentSpace
            for space in spaceList {
                if let sid, space == sid {
                    validateAndCheckForWindows(on: sid)
                } else {
                    space_manager_mark_view_invalid(SpaceManager.shared, space)
                }
            }
        }

        windowAnimationDuration = animationDuration
    }

    func handleDisplayAddAndRemove(_ did: DisplayID)
    {
        guard let spaceList = did.spaces else { return }

        for space in spaceList where space.isUser {
            if let windowList = windows(onSpace: space) {
                let owner = space_manager_find_view(SpaceManager.shared, space)
                if owner.layout != .float {
                    checkForWindows(on: owner, in: windowList)
                }
            }
            break
        }

        let sid = did.currentSpace
        for space in spaceList {
            if let sid, space == sid {
                space_manager_refresh_view(SpaceManager.shared, sid)
            } else {
                space_manager_mark_view_invalid(SpaceManager.shared, space)
            }
        }
    }
}
