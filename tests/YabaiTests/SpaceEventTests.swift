import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

extension DaemonState {
  @Suite
  @WM struct SpaceEventTests {
    @Test func spaceChangedUpdatesCurrentAndRecentSpace() {
      let sm = SpaceManager.shared
      let previous = SpaceID(0xFFFF_1001)
      let recent = SpaceID(0xFFFF_1002)
      let active = SpaceID(0xFFFF_1003)
      sm.currentSpaceID = previous
      sm.lastSpaceID = recent

      var invalidations = 0
      var refreshes = 0
      var signals: [SignalType] = []
      var snapshotReads = 0

      EventHandler.shared.spaceChanged(
        snapshot: {
          #expect(invalidations == 1)
          snapshotReads += 1
          return SpaceChangeSnapshot(activeSpace: active)
        },
        invalidateSpaceCaches: { invalidations += 1 },
        refreshCurrentSpace: { refreshes += 1 },
        pushSignal: { signals.append($0) })

      #expect(sm.currentSpaceID == active)
      #expect(sm.lastSpaceID == previous)
      #expect(invalidations == 1)
      #expect(snapshotReads == 1)
      #expect(refreshes == 1)
      #expect(signals == [.spaceChanged])
    }

    @Test func displayChangedUpdatesCurrentAndRecentDisplayAndSpace() {
      let dm = DisplayManager.shared
      let sm = SpaceManager.shared
      let previousDisplay = DisplayID(0xFFFF_0001)
      let recentDisplay = DisplayID(0xFFFF_0002)
      let activeDisplay = DisplayID(0xFFFF_0003)
      let previousSpace = SpaceID(0xFFFF_2001)
      let recentSpace = SpaceID(0xFFFF_2002)
      let activeSpace = SpaceID(0xFFFF_2003)
      dm.currentDisplayID = previousDisplay
      dm.lastDisplayID = recentDisplay
      sm.currentSpaceID = previousSpace
      sm.lastSpaceID = recentSpace

      var invalidations = 0
      var refreshes = 0
      var signals: [SignalType] = []
      var snapshotReads = 0

      EventHandler.shared.displayChanged(
        snapshot: {
          #expect(invalidations == 1)
          snapshotReads += 1
          return DisplayChangeSnapshot(
            activeDisplay: activeDisplay,
            currentSpace: activeSpace,
            currentSpaceDisplay: activeDisplay)
        },
        invalidateSpaceCaches: { invalidations += 1 },
        refreshCurrentSpace: { refreshes += 1 },
        pushSignal: { signals.append($0) })

      #expect(dm.currentDisplayID == activeDisplay)
      #expect(dm.lastDisplayID == previousDisplay)
      #expect(sm.currentSpaceID == activeSpace)
      #expect(sm.lastSpaceID == previousSpace)
      #expect(invalidations == 1)
      #expect(snapshotReads == 1)
      #expect(refreshes == 1)
      #expect(signals == [.displayChanged])
    }

    @Test func duplicateDisplayChangeInvalidatesCachesButDoesNotSignal() {
      let dm = DisplayManager.shared
      let sm = SpaceManager.shared
      let activeDisplay = DisplayID(0xFFFF_0004)
      let recentDisplay = DisplayID(0xFFFF_0005)
      let activeSpace = SpaceID(0xFFFF_2004)
      let recentSpace = SpaceID(0xFFFF_2005)
      dm.currentDisplayID = activeDisplay
      dm.lastDisplayID = recentDisplay
      sm.currentSpaceID = activeSpace
      sm.lastSpaceID = recentSpace

      var invalidations = 0
      var refreshes = 0
      var signals: [SignalType] = []

      EventHandler.shared.displayChanged(
        snapshot: {
          #expect(invalidations == 1)
          return DisplayChangeSnapshot(
            activeDisplay: activeDisplay,
            currentSpace: nil,
            currentSpaceDisplay: nil)
        },
        invalidateSpaceCaches: { invalidations += 1 },
        refreshCurrentSpace: { refreshes += 1 },
        pushSignal: { signals.append($0) })

      #expect(dm.currentDisplayID == activeDisplay)
      #expect(dm.lastDisplayID == recentDisplay)
      #expect(sm.currentSpaceID == activeSpace)
      #expect(sm.lastSpaceID == recentSpace)
      #expect(invalidations == 1)
      #expect(refreshes == 0)
      #expect(signals.isEmpty)
    }

    @Test func mismatchedDisplaySnapshotUpdatesStateWithoutRefreshingOrSignaling() {
      let dm = DisplayManager.shared
      let sm = SpaceManager.shared
      let previousDisplay = DisplayID(0xFFFF_0006)
      let activeDisplay = DisplayID(0xFFFF_0007)
      let expectedDisplay = DisplayID(0xFFFF_0008)
      let previousSpace = SpaceID(0xFFFF_2006)
      let activeSpace = SpaceID(0xFFFF_2007)
      dm.currentDisplayID = previousDisplay
      sm.currentSpaceID = previousSpace

      var invalidations = 0
      var refreshes = 0
      var signals: [SignalType] = []

      EventHandler.shared.displayChanged(
        snapshot: {
          #expect(invalidations == 1)
          return DisplayChangeSnapshot(
            activeDisplay: activeDisplay,
            currentSpace: activeSpace,
            currentSpaceDisplay: expectedDisplay)
        },
        invalidateSpaceCaches: { invalidations += 1 },
        refreshCurrentSpace: { refreshes += 1 },
        pushSignal: { signals.append($0) })

      #expect(dm.currentDisplayID == activeDisplay)
      #expect(dm.lastDisplayID == previousDisplay)
      #expect(sm.currentSpaceID == activeSpace)
      #expect(sm.lastSpaceID == previousSpace)
      #expect(invalidations == 1)
      #expect(refreshes == 0)
      #expect(signals.isEmpty)
    }
  }
}
