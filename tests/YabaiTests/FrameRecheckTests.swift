import CoreGraphics
import OrderedCollections
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: A tiled window that something else moves off its tile is flushed back, and checked again once its frame
// changes have settled (P5.7 -var: macOS tiled the middle window after a click, and the flush lost to a later step).
// The fake windows have no AX element, so their AX frame is zero, which is off every tile here. In headless mode a
// flush skips a window whose request already matches its tile, as the daemon skips one whose request and window server
// bounds match: the handler's flush writes nothing, like the flush that lost, and the check must write it anyway.
//

/// The tiled windows w1, w2 and w3 of a Workspace laid out in the headless display frame, with the placements drained.
@WM private func tiledWorkspace() -> Workspace {
  let workspace = Workspace()
  for n: UInt32 in 1...3 { workspace.open(n) }
  workspace.view.update()
  workspace.view.flush()
  _ = Headless.drain()
  return workspace
}

extension DaemonState {
  @Suite
  @WM struct FrameRecheckTests {
    @Test func movedTiledWindowIsCheckedAgainAndPutOnItsTile() async {
      defer { EventLoop.cancel(key: .windowFrameRecheck) }
      _ = tiledWorkspace()
      let wm = WindowManager.shared
      let target = wm.window[wid(2)]!
      let tile = target.frame
      #expect(tile.origin.x > 0)

      await EventHandler.shared.handle(.windowMoved(windowID: target.id))

      #expect(Headless.drain().placements.isEmpty)
      #expect(wm.frameRecheckWindows == [target.id])

      EventHandler.shared.windowFrameRecheck()

      #expect(
        Headless.drain().placements == [
          RecordedPlacement(
            windowID: target.id, x: Float(tile.minX), y: Float(tile.minY), w: Float(tile.width),
            h: Float(tile.height))
        ])
      #expect(target.frame == tile)
      #expect(wm.frameRecheckWindows.isEmpty)
    }

    @Test func recheckFlushesOnlyWindowsOffTheirTile() {
      let workspace = tiledWorkspace()
      let wm = WindowManager.shared
      let ms = MouseState.shared
      let (w1, w2, w3) = (wm.window[wid(1)]!, wm.window[wid(2)]!, wm.window[wid(3)]!)
      let tile2 = w2.frame
      let floating = Window(id: wid(9))
      wm.window[floating.id] = floating
      ms.currentAction = .move
      ms.window = w3
      defer {
        ms.currentAction = .none
        ms.window = nil
      }
      let off = CGRect(x: 0, y: 30, width: 720, height: 870)

      let views = wm.retileWindowsOffTile([
        (w1, w1.frame), (w2, off), (w3, off), (floating, off),
      ])

      #expect(views.count == 1 && views.first === workspace.view)
      #expect(Headless.drain().placements.map(\.windowID) == [w2.id])
      #expect(w2.frame == tile2)
      #expect(w3.frame != off)
    }

    @Test func recheckOfWindowsAtTheirTileFlushesNothing() {
      _ = tiledWorkspace()
      let wm = WindowManager.shared
      let windows = [wid(1), wid(2), wid(3)].map { wm.window[$0]! }

      let views = wm.retileWindowsOffTile(windows.map { ($0, $0.frame) })

      #expect(views.isEmpty)
      #expect(Headless.drain().placements.isEmpty)
    }
  }
}
