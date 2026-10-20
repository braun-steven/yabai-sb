import Testing
import CoreGraphics
import CPrivate
import OSAX
import YabaiCore
@testable import Yabai
import YabaiTestSupport

//
// NOTE: The daemonFixture trait turns headless mode on, so these flushes and payload messages are recorded instead of
// reaching the window server or Dock. The ids are large fake values that no real window or space uses.
//

extension DaemonState
{
    @Suite
    @WM struct HeadlessTests
    {
        @Test func flushRecordsPlacementsOnce()
        {
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
            #expect(Headless.drain().placements == [
                RecordedPlacement(windowID: first, x: 0, y: 0, w: 500, h: 800),
                RecordedPlacement(windowID: second, x: 500, y: 0, w: 500, h: 800),
            ])
            #expect(WindowManager.shared.window[second]?.frame == CGRect(x: 500, y: 0, width: 500, height: 800))

            // the windows are already where the tree puts them
            target.flush()
            #expect(Headless.drain().placements.isEmpty)
        }

        @Test func payloadMessageIsRecorded()
        {
            let window: WindowID = 0xFFFF_0001

            #expect(ScriptingAddition.shared.setLayer(3, of: window))

            var expected = SAPayload(); expected.pack(window); expected.pack(Int32(3))
            let log = Headless.drain()
            #expect(log.messages == [expected.message(SA_OPCODE_WINDOW_LAYER)])
            #expect(log.messages.first?[2] == UInt8(SA_OPCODE_WINDOW_LAYER.rawValue))
        }
    }
}
