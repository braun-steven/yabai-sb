import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: `space --pin` and the label changes that keep or drop a pin. The suite is DaemonState: the commands change the
// labels and the pins of SpaceManager, which the fixture resets. Pinning to a display needs a display of the window
// server, so these tests set the pins directly and check what the commands do to them. The decisions of the pins are
// in tests/YabaiCoreTests/SpacePinningTests.swift. The reconcile passes are not run here: they move spaces through the
// scripting addition and the window server.
//

/// A display uuid that no display has: a pin to it is stored, and the query shows no display for it.
private let unknownDisplayUUID = "00000000-0000-0000-0000-000000000000"

extension DaemonState {
  @Suite
  @WM struct SpacePinCommandTests {
    /// Creates the workspace's view and labels its space "work".
    @WM private static func labelWork() {
      _ = Workspace()
      SpaceManager.shared.labels.set(id: Workspace.sid, name: "work")
    }

    @Test func unpinRemovesThePin() {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      #expect(Golden.run("space work --pin") == [])
      #expect(SpaceManager.shared.pins.isEmpty)
      #expect(SpaceManager.shared.labels.name(of: Workspace.sid) == "work")
    }

    @Test func anUnknownDisplaySelectorFailsAndKeepsThePin() {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      let response = Golden.run("space work --pin --foo")
      #expect(String(decoding: response, as: UTF8.self).hasPrefix("value '--foo'"))
      #expect(SpaceManager.shared.pins.display(of: "work") == unknownDisplayUUID)
    }

    @Test func removingTheLabelDropsThePin() {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      #expect(Golden.run("space work --label") == [])
      #expect(SpaceManager.shared.labels.name(of: Workspace.sid) == nil)
      #expect(SpaceManager.shared.pins.isEmpty)
    }

    @Test func replacingTheLabelDropsThePinOfTheOldLabel() {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      #expect(Golden.run("space work --label play") == [])
      #expect(SpaceManager.shared.labels.id(named: "play") == Workspace.sid)
      #expect(SpaceManager.shared.pins.isEmpty)
    }

    @Test func aPinFollowsItsLabelToAnotherSpace() {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      // NOTE: the label moves to another space without a view (its space is not needed to keep the pin).
      let other = SpaceID(0xFFFF_0200)
      SpaceManager.shared.labels.set(id: other, name: "work")
      SpaceManager.shared.dropOrphanedPins()

      #expect(SpaceManager.shared.labels.id(named: "work") == other)
      #expect(SpaceManager.shared.pins.display(of: "work") == unknownDisplayUUID)
    }

    @Test func queryShowsZeroWhenThePinnedDisplayIsNotConnected() throws {
      Self.labelWork()
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)

      let bytes = Golden.run("query --spaces id,pinned-display --space work")
      let info = try #require(
        try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
      #expect(info["pinned-display"] as? Int == 0)
      #expect(info.count == 2)
    }

    @Test func queryShowsZeroWithoutAPin() throws {
      Self.labelWork()

      let bytes = Golden.run("query --spaces id,pinned-display --space work")
      let info = try #require(
        try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
      #expect(info["pinned-display"] as? Int == 0)
    }
  }
}
