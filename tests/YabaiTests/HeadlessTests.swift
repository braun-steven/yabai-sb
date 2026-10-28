import CPrivate
import CoreGraphics
import OSAX
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: The daemonFixture trait turns headless mode on, so these flushes and payload messages are recorded instead of
// reaching the window server or Dock. The ids are large fake values that no real window or space uses.
//

extension DaemonState {
  @Suite
  @WM struct HeadlessTests {
    @Test func flushRecordsPlacementsOnce() {
      let first: WindowID = 0xFFFF_0001
      let second: WindowID = 0xFFFF_0002
      let target = View(sid: 0xFFFF_0000)
      target.layout = .tree
      target.area = Area(x: 0, y: 0, w: 1000, h: 800)
      target.tree = Con(layout: .splitH)
      treeTestLeaf(target.tree!, first)
      treeTestLeaf(target.tree!, second)
      for id in [first, second] { WindowManager.shared.window[id] = Window(id: id) }
      target.updateTree()
      target.isDirty = true

      target.flush()

      #expect(!target.isDirty)
      #expect(
        Headless.drain().placements == [
          RecordedPlacement(windowID: first, x: 0, y: 0, w: 500, h: 800),
          RecordedPlacement(windowID: second, x: 500, y: 0, w: 500, h: 800),
        ])
      #expect(
        WindowManager.shared.window[second]?.frame == CGRect(x: 500, y: 0, width: 500, height: 800))

      // the windows are already where the tree puts them
      target.flush()
      #expect(Headless.drain().placements.isEmpty)
    }

    @Test func payloadMessageIsRecorded() {
      let window: WindowID = 0xFFFF_0001

      #expect(ScriptingAddition.shared.setLayer(3, of: window))

      var expected = SAPayload()
      expected.pack(window)
      expected.pack(Int32(3))
      let log = Headless.drain()
      #expect(log.messages == [expected.message(SA_OPCODE_WINDOW_LAYER)])
      #expect(log.messages.first?[2] == UInt8(SA_OPCODE_WINDOW_LAYER.rawValue))
    }

    // A single window is ordered as a one-entry window order list.
    @Test(arguments: [("--raise w1", Int32(1), UInt32(1)), ("--lower", Int32(-1), UInt32(0))])
    func raiseAndLowerSendOneEntryOrderList(command: String, order: Int32, relativeTo: UInt32) {
      let space = Workspace()
      for n: UInt32 in 1...2 { space.open(n, focus: true) }
      space.act(2)
      space.settle()

      #expect(Golden.run(windowCommand(command)).isEmpty)

      var expected = SAPayload()
      expected.pack(Int32(1))
      expected.pack(wid(2))
      expected.pack(order)
      expected.pack(relativeTo == 0 ? 0 : wid(relativeTo).rawValue)
      #expect(Headless.drain().messages == [expected.message(SA_OPCODE_WINDOW_ORDER_LIST)])
    }
  }
}
