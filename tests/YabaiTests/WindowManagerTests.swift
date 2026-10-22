import CPrivate
import Foundation
import SortedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

// NOTE: Ported from tests/src/window_frame.c; the rule tests are in RuleTests.swift. The window managers of these tests
// are local, so they do not touch the state of the daemon.

/// A window manager with the defaults of its fields, released by windowManagerFree.
@WM private func windowManagerCreate() -> WindowManager {
  return WindowManager()
}

@WM private func windowManagerFree(_ wm: WindowManager) {
  wm.rules = []
  wm.window.removeAll()
}

/// A valid window with an id and an application.
@WM private func windowCreate(_ id: WindowID, _ owner: Application? = nil) -> Window {
  let result = Window(id: id)
  result.application = owner
  return result
}

@Test("window_pending_focus") @WM func windowPendingFocus() {
  let wm = windowManagerCreate()
  let target = windowCreate(42)
  defer { windowManagerFree(wm) }

  wm.addWindow(target)

  #expect(wm.consumePendingFocusWindow(now: OSTimer.now) == nil)

  wm.setPendingFocus(42)
  #expect(wm.consumePendingFocusWindow(now: OSTimer.now) == target)
  #expect(wm.focus.pending?.windowID == 42)

  //
  // NOTE: A pending focus expires, and is dropped for windows that no longer exist.
  //

  wm.focus.setPending(42, at: OSTimer.now - UInt64(Double(OSTimer.frequency) * 0.6))
  #expect(wm.consumePendingFocusWindow(now: OSTimer.now) == nil)
  #expect(wm.focus.pending == nil)

  wm.setPendingFocus(7)
  #expect(wm.consumePendingFocusWindow(now: OSTimer.now) == nil)
  #expect(wm.focus.pending == nil)
}

@Test("window_pending_focus_within_timeout") @WM func windowPendingFocusWithinTimeout() {
  let wm = windowManagerCreate()
  let target = windowCreate(43)
  defer { windowManagerFree(wm) }

  wm.addWindow(target)

  //
  // NOTE: A pending focus that has not expired is the acting window, and it stays pending until its window reports focus.
  //

  wm.focus.setPending(43, at: OSTimer.now - UInt64(Double(OSTimer.frequency) * 0.2))
  #expect(wm.actingWindow() == target)
  #expect(wm.focus.pending?.windowID == 43)
  #expect(wm.consumePendingFocusWindow(now: OSTimer.now) == target)
  #expect(wm.focus.pending?.windowID == 43)
}

@Test("window_lost_front_switched_events") @WM func windowLostFrontSwitchedEvents() {
  let wm = windowManagerCreate()
  defer { windowManagerFree(wm) }

  #expect(!wm.focus.hasLostFrontSwitchedEvent(for: 77))

  wm.focus.addLostFrontSwitchedEvent(for: 77)
  wm.focus.addLostFrontSwitchedEvent(for: 78)
  #expect(wm.focus.hasLostFrontSwitchedEvent(for: 77))

  wm.focus.removeLostFrontSwitchedEvent(for: 77)
  #expect(!wm.focus.hasLostFrontSwitchedEvent(for: 77))
  #expect(wm.focus.hasLostFrontSwitchedEvent(for: 78))
}

@Test("window_unresolved_list") @WM func windowUnresolvedList() {
  let wm = windowManagerCreate()
  let windows = [12, 14, 11, 13].map { windowCreate($0) }
  defer { windowManagerFree(wm) }

  wm.addWindow(windows[0])
  wm.addWindow(windows[1])
  #expect(wm.unresolvedWindows(in: [11, 12, 13, 14]) == [11, 13])

  wm.addWindow(windows[2])
  wm.addWindow(windows[3])
  #expect(wm.unresolvedWindows(in: [11, 12, 13, 14]).isEmpty)
}

@Test("window_validity") @WM func windowValidity() {
  let target = windowCreate(5)

  #expect(target.isValid == true)
  #expect(target.invalidate() == true)
  #expect(target.isValid == false)

  // NOTE: only one caller may claim the destruction of a window
  #expect(target.invalidate() == false)
}

//
// NOTE: 1 has the children 2 and 3, 3 has the child 4, and 9 belongs to another window. The direct relations
// make every window a direct child, which needs as many entries as there are relations.
//

@Test("window_child_windows_collect") @WM func windowChildWindowsCollect() {
  var parentList: [WindowID?] = [3, 1, 9, 1]
  #expect(
    WindowManager.collectChildWindows(1, parents: &parentList, children: [4, 2, 8, 3]) == [2, 3, 4])

  var directParent: [WindowID?] = [1, 1, 1]
  #expect(
    WindowManager.collectChildWindows(1, parents: &directParent, children: [2, 3, 4]).count == 3)

  // NOTE: a cycle does not repeat windows
  var cycleParent: [WindowID?] = [1, 2]
  #expect(WindowManager.collectChildWindows(1, parents: &cycleParent, children: [2, 1]).count == 2)

  var emptyParent: [WindowID?] = []
  #expect(WindowManager.collectChildWindows(1, parents: &emptyParent, children: []).isEmpty)
}
