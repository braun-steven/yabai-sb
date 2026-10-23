import AppKit
import CPrivate
import SortedCollections
import YabaiCore

extension WindowManager {
  func window(for id: WindowID) -> Window? {
    window[id]
  }

  func removeWindow(_ id: WindowID) {
    forget(id)
    window[id] = nil
  }

  //
  // NOTE: Clears the state that is keyed by the id of a window that is gone, and only that id. Called by removeWindow,
  // so every removal of a window clears the same tables. Left alone, and why:
  // - windowAnimations (WindowAnimation.swift): the display link of an animation removes its entry and destroys its
  //   proxy when it finishes, and a new animation of the window takes over the entry; clearing it here would leak the
  //   proxy and change that hand-over.
  // - tabBarHits (TabBar.swift): a snapshot that publishHits rebuilds on every bar update.
  // - tabBarPointer (TabBar.swift): a change cache for the event tap, refreshed by the next pointer move.
  // - focused, last and pending: FocusState owns them (FocusState.swift). The focus hand-over reads them after the
  //   removal, so they are left alone here. The lost focus event of the id is cleared below.
  // - Application.focusedWindowID: per application, read by its front-switch handler.
  // - Border.show and Border.hide (Border.swift): batch lists, emptied by endBatch, which skips an id without a border.
  // Cleared here: the window label of the id (labels, WindowManager.swift), the floating frame of the window
  // (`Window.lastFloatingFrame`, read by its next float toggle), and the AX destroyed mark of the id
  // (axDestroyedWindowIDs, Window.swift). Its destroyed event, queued behind the mark, finds no window and clears it
  // too, for a mark that arrives after this removal.
  //
  func forget(_ id: WindowID) {
    unmarkAXDestroyed(id)
    Border.remove(id)
    focus.removeLostFocusedEvent(for: id)
    removeManagedWindow(id)
    labels.remove(id: id)
    window[id]?.lastFloatingFrame = nil

    // NOTE: teardown clears the mouse state before it removes the window; clearing it here too keeps removeWindow
    // alone sufficient. Only the fields of this window change.
    let mouse = MouseState.shared
    if mouse.window?.id == id { mouse.clearWindow() }
    if mouse.ffmWindowID == id { mouse.ffmWindowID = nil }
    if mouse.feedbackWindowID == id {
      mouse.feedbackWindowID = nil
      mouse.feedbackDirection = nil
    }
  }

  func addWindow(_ target: Window) {
    if window[target.id] == nil { window[target.id] = target }
  }

  func application(for pid: pid_t) -> Application? {
    application[pid]
  }

  func removeApplication(pid: pid_t) {
    application.removeValue(forKey: pid)
  }

  func addApplication(_ owner: Application) {
    if application[owner.pid] == nil { application[owner.pid] = owner }
  }

  /// The windows owned by an application, in window id order.
  func windows(for owner: Application) -> [Window] {
    window.values.filter { $0.application == owner }
  }
}
