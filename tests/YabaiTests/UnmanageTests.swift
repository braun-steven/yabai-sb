import OSAX
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: A window leaves its tree without being destroyed in two ways: reconciliation finds it gone from its space, and a
// float toggle takes it out of its tree. Both untile it, restore its layer and shadow, and drop it from the managed
// windows. These tests pin the tree, the managed windows, the dirty flag, the placements and the payload messages (the
// layer, then the shadow), so that the unmanage helper keeps them.
//

/// The payload message that sets the layer of window n.
@WM private func layerMessage(_ n: UInt32, _ layer: WindowLayer) -> [UInt8]? {
  var payload = SAPayload()
  payload.pack(wid(n))
  payload.pack(layer.level)
  return payload.message(SA_OPCODE_WINDOW_LAYER)
}

/// The payload message that sets the shadow of window n.
@WM private func shadowMessage(_ n: UInt32, _ shadow: Bool) -> [UInt8]? {
  var payload = SAPayload()
  payload.pack(wid(n))
  payload.pack(shadow)
  return payload.message(SA_OPCODE_WINDOW_SHADOW)
}

/// Three tiled windows w1, w2 and w3 of a Workspace, with the messages and placements of opening them drained.
@WM private func tiledWorkspace() -> Workspace {
  let workspace = Workspace()
  workspace.open(1, focus: true)
  workspace.open(2)
  workspace.open(3)
  _ = Headless.drain()
  return workspace
}

extension DaemonState {
  @Suite
  @WM struct UnmanageTests {
    @Test func reconciliationUntilesAWindowGoneFromItsSpace() {
      let workspace = tiledWorkspace()
      let wm = WindowManager.shared
      workspace.view.isDirty = false

      // w2 is no longer on the space: the reconcile path removes it from the tree and the managed windows.
      wm.validateWindows(on: workspace.view, against: [wid(1), wid(3)])

      #expect(workspace.dump == "splith\n  w1 0.5000\n  w3 0.5000")
      #expect(
        wm.managedWindows.keys.map(\.rawValue).sorted() == [
          treeTestWindowBase + 1, treeTestWindowBase + 3,
        ])
      #expect(workspace.view.isDirty)
      #expect(wm.window[wid(2)]?.hasShadow == true)

      // the layer comes first, then the shadow: removing from the tree sends nothing
      let log = Headless.drain()
      #expect(log.messages == [layerMessage(2, .normal), shadowMessage(2, true)])
      #expect(log.placements.isEmpty)

      // the dirty view is flushed later by the caller
      workspace.view.flush()
      #expect(
        Headless.drain().placements == [
          RecordedPlacement(windowID: wid(1), x: 0, y: 0, w: 600, h: 800),
          RecordedPlacement(windowID: wid(3), x: 600, y: 0, w: 600, h: 800),
        ])
    }

    @Test func floatToggleUnmanagesTheWindowAndFlushesItsView() {
      let workspace = tiledWorkspace()
      let wm = WindowManager.shared
      let target = wm.window[wid(2)]!

      // eligible for management without an accessibility role, as a rule-managed window is
      target.isRoot = true
      target.isManagedByRule = true

      wm.makeWindowFloating(target, shouldFloat: true, force: true)

      #expect(target.isFloating)
      #expect(workspace.dump == "splith\n  w1 0.5000\n  w3 0.5000")
      #expect(
        wm.managedWindows.keys.map(\.rawValue).sorted() == [
          treeTestWindowBase + 1, treeTestWindowBase + 3,
        ])
      #expect(!workspace.view.isDirty)

      let log = Headless.drain()
      #expect(log.messages == [layerMessage(2, .normal), shadowMessage(2, true)])
      #expect(
        log.placements == [
          RecordedPlacement(windowID: wid(1), x: 0, y: 0, w: 600, h: 800),
          RecordedPlacement(windowID: wid(3), x: 600, y: 0, w: 600, h: 800),
        ])
    }

    // NOTE: The shadow is set after the window left its view, so the managed mode sees no view and sets a shadow.
    @Test(arguments: [
      (PurifyMode.disabled, true), (PurifyMode.managed, true), (PurifyMode.always, false),
    ])
    func floatToggleSetsTheShadowAfterLeavingTheView(_ mode: PurifyMode, _ shadow: Bool) {
      let workspace = tiledWorkspace()
      let wm = WindowManager.shared
      let target = wm.window[wid(2)]!
      target.isRoot = true
      target.isManagedByRule = true
      Config.current.shadow.mode = mode

      wm.makeWindowFloating(target, shouldFloat: true, force: true)

      #expect(Headless.drain().messages.last == shadowMessage(2, shadow))
      #expect(target.hasShadow == shadow)
      #expect(workspace.dump == "splith\n  w1 0.5000\n  w3 0.5000")
    }
  }
}
