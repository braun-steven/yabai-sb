import ApplicationServices
import CPrivate
import Foundation
import Logging
import OrderedCollections
import SortedCollections
import YabaiCore

extension WindowManager {
  func initialize() {
    let systemElement = AXUIElement.systemWide()
    systemElement.setMessagingTimeout(1.0)
    self.systemElement = systemElement

    _ = TabBar.setFont(TabBar.defaultFont)

    application = [:]
    window = [:]
    managedWindows = [:]
    focus.clearLostEvents()
    axBreaker = AXBreaker()
    frameRecheckWindows = []
  }

  func begin() {
    autoreleasepool {
      // Applications in pid order, so their windows tile in the same order every start.
      for candidate in ProcessManager.shared.processes.values.sorted(by: { $0.pid < $1.pid }) {
        if candidate.isObservable() {
          let created = Application(process: candidate)

          if created.observe() {
            addApplication(created)
            addExistingApplicationWindows(created, isRefreshing: false)
          } else {
            created.unobserve()
            created.destroy()
          }
        } else {
          Logger.processes.debug(
            "\(candidate.nameAndPID) is not observable, subscribing to activationPolicy changes")
          candidate.observeActivationPolicy()
        }
      }
    }

    if let target = focusedWindow {
      focus.focusRestored(to: target.id, psn: target.application.psn)
      setWindowOpacity(target, to: Config.current.windowOpacity.active)
    }
  }

  /// Requests the SkyLight notifications of all known windows. Daemon.run calls it before the event loop runs, so it is not @WM.
  func updateWindowNotifications() {
    // NOTE: Headless mode (the tests) must not ask the window server for notifications.
    if Headless.isEnabled { return }

    // NOTE(asmvik): Subscribe to all windows because of the window destroyed (and ordered) notifications
    SLS.requestNotifications(SLS.connection, forWindows: window.values.map(\.id))
  }
}
