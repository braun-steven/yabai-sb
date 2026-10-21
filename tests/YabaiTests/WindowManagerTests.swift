import Foundation
import Testing
import CPrivate
import YabaiCore
@testable import Yabai
import YabaiTestSupport

// NOTE: Ported from tests/src/window_frame.c; the rule tests are in RuleTests.swift. The window managers of these tests
// are local, so they do not touch the state of the daemon.

/// A window manager with the defaults of its fields, released by windowManagerFree.
@WM private func windowManagerCreate() -> WindowManager
{
    return WindowManager()
}

@WM private func windowManagerFree(_ wm: WindowManager)
{
    wm.rules = []
    wm.window.removeAll()
}

/// A valid window with an id and an application.
@WM private func windowCreate(_ id: WindowID, _ owner: Application? = nil) -> Window
{
    let result = Window(id: id)
    result.application = owner
    return result
}

@Test("window_pending_focus") @WM func windowPendingFocus()
{
    let wm = windowManagerCreate()
    let target = windowCreate(42)
    defer { windowManagerFree(wm) }

    wm.addWindow(target)

    #expect(wm.pendingFocusWindow == nil)

    wm.setPendingFocus(42)
    #expect(wm.pendingFocusWindow == target)
    #expect(wm.pendingFocusWindowID == 42)

    //
    // NOTE: A pending focus expires, and is dropped for windows that no longer exist.
    //

    wm.pendingFocusTime = OSTimer.now - UInt64(Double(OSTimer.frequency) * 0.6)
    #expect(wm.pendingFocusWindow == nil)
    #expect(wm.pendingFocusWindowID == nil)

    wm.setPendingFocus(7)
    #expect(wm.pendingFocusWindow == nil)
    #expect(wm.pendingFocusWindowID == nil)
}

@Test("window_unresolved_list") @WM func windowUnresolvedList()
{
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

@Test("window_validity") @WM func windowValidity()
{
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

@Test("window_child_windows_collect") @WM func windowChildWindowsCollect()
{
    var parentList: [WindowID?] = [3, 1, 9, 1]
    #expect(WindowManager.collectChildWindows(1, parents: &parentList, children: [4, 2, 8, 3]) == [2, 3, 4])

    var directParent: [WindowID?] = [1, 1, 1]
    #expect(WindowManager.collectChildWindows(1, parents: &directParent, children: [2, 3, 4]).count == 3)

    // NOTE: a cycle does not repeat windows
    var cycleParent: [WindowID?] = [1, 2]
    #expect(WindowManager.collectChildWindows(1, parents: &cycleParent, children: [2, 1]).count == 2)

    var emptyParent: [WindowID?] = []
    #expect(WindowManager.collectChildWindows(1, parents: &emptyParent, children: []).isEmpty)
}
