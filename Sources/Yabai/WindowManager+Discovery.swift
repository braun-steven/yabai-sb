import AppKit
import ApplicationServices
import CPrivate
import Foundation
import Logging
import OrderedCollections
import YabaiCore

struct DiscoveryRulePlan {
  let rulesAfterApplication: [Rule]
  let manageEffects: RuleEffects?
  let effects: RuleEffects?
  let isEligible: Bool
  let insertion: InsertDirection?
}

// NOTE: Discovering the windows of an application: creating a window applies the rules and decides whether
// it floats. Windows on other spaces are missing from the accessibility list of an application; they are
// resolved later, or found by element id.

// NOTE(asmvik): Print window information when debug_output is enabled.
// Useful for identifying and creating rules if this window should in fact be managed.

extension WindowManager {
  /// nil when the window is ignored (AXUnknown, or it cannot be observed).
  @discardableResult
  func createAndAddWindow(
    _ owner: Application, reference: AXUIElement, id: WindowID, includingOneShotRules: Bool
  ) -> Window? {
    let target = Window(application: owner, reference: reference, id: id)

    let windowTitle = target.ax.title ?? ""
    let windowRole = target.ax.role ?? ""
    let windowSubrole = target.ax.subrole ?? ""
    Logger.windows.debug(
      "adding window \(target.id) \(owner.name) - \(windowTitle) (\(windowRole):\(windowSubrole):\(target.isRoot ? 1 : 0))"
    )

    if target.isUnknown {
      Logger.windows.debug("ignoring AXUnknown window \(owner.name) \(target.id)")
      focus.removeLostFocusedEvent(for: target.id)
      target.destroy()
      return nil
    }

    // NOTE: Attempt to track all windows.
    if !target.observe() {
      Logger.windows.debug("could not observe \(owner.name) \(target.id)")
      focus.removeLostFocusedEvent(for: target.id)
      target.unobserve()
      target.destroy()
      return nil
    }

    if focus.hasLostFocusedEvent(for: target.id) {
      EventLoop.post(.windowFocused(windowID: target.id))
      focus.removeLostFocusedEvent(for: target.id)
    }

    addWindow(target)

    // NOTE: Only root windows are eligible for management.
    if target.isRoot {
      if applyDiscoveryRules(
        to: target, title: windowTitle, role: windowRole, subrole: windowSubrole,
        includingOneShotRules: includingOneShotRules)
      {
        purifyWindow(target)
        setWindowOpacity(target, to: Config.current.windowOpacity.normal)

        if owner.isHidden { return target }
        if target.isMinimized { return target }
        if target.isFullscreen { return target }
        if target.isManagedByRule { return target }

        if target.isFullscreenByRule {
          target.isFullscreenByRule = false
          return target
        }

        if target.id.isSticky || !target.canMove || !target.isStandard || !target.isStandardLevel
          || (!target.canResize && target.isUndersized)
        {
          target.isFloating = true
        }
      } else {
        Logger.windows.debug("ignoring incorrectly marked window \(owner.name) \(target.id)")
        target.isFloating = true
        debugWindowInfo(target)
      }
    } else {
      Logger.windows.debug("ignoring child window \(owner.name) \(target.id)")
      target.isFloating = true
      debugWindowInfo(target)
    }

    return target
  }

  /// Applies the discovery rule policy to a root window from its immutable AX strings. Manage rules run first so a
  /// rule can make a nonstandard window eligible for the effects round. Returns whether the window is eligible.
  func applyDiscoveryRules(
    to target: Window,
    title: String,
    role: String,
    subrole: String,
    includingOneShotRules: Bool
  ) -> Bool {
    let plan = discoveryRulePlan(
      for: target, title: title, role: role, subrole: subrole,
      includingOneShotRules: includingOneShotRules)
    rules = plan.rulesAfterApplication

    if let manageEffects = plan.manageEffects {
      applyManageRuleEffects(manageEffects, to: target)
    }

    guard plan.isEligible else { return false }

    target.isEligible = true
    if let effects = plan.effects { applyRuleEffects(effects, to: target) }
    target.insertionByRule = plan.insertion
    return true
  }

  /// Plans the discovery rule rounds without applying rule effects or retaining one-shot matches in the manager.
  /// Production commits the returned rule state and applies the effects in order; tests can inspect the same policy
  /// without reaching AX, SkyLight or the scripting addition.
  func discoveryRulePlan(
    for target: Window,
    title: String,
    role: String,
    subrole: String,
    includingOneShotRules: Bool
  ) -> DiscoveryRulePlan {
    let originalRules = rules
    defer { rules = originalRules }

    // NOTE: Many windows misreport their accessibility role, so rules let users mark these windows
    // for management. Apply this rule before other rule properties. Without a matching rule, ignore
    // windows whose role is not kAXWindowRole.
    var manageEffects = RuleEffects()
    let hasManageMatches = combineMatchingRuleEffects(
      for: target, title: title, role: role, subrole: subrole,
      includingOneShotRules: includingOneShotRules, manageRound: true, into: &manageEffects)

    let managedByRule = manageEffects.manage ?? target.isManagedByRule
    let originalManagedByRule = target.isManagedByRule
    defer { target.isManagedByRule = originalManagedByRule }
    target.isManagedByRule = managedByRule
    let isEligible = target.isEligibleForManagement

    var effects: RuleEffects?
    if isEligible {
      var combinedEffects = RuleEffects()
      if combineMatchingRuleEffects(
        for: target, title: title, role: role, subrole: subrole,
        includingOneShotRules: includingOneShotRules, manageRound: false, into: &combinedEffects)
      {
        effects = combinedEffects
      }
    }

    // NOTE: insert= places a window only as it is created, so it is recorded only for a new window (added with
    // one-shot rules included). Windows that exist when yabai starts, or that a later discovery finds, keep their
    // place: recording it for them would stack or split windows that are already tiled.
    return DiscoveryRulePlan(
      rulesAfterApplication: rules,
      manageEffects: hasManageMatches ? manageEffects : nil,
      effects: effects,
      isEligible: isEligible,
      insertion: includingOneShotRules ? effects?.insertionForNewWindow : nil)
  }

  // NOTE: The space a new window is managed on, as selected by window_origin_display.
  func originSpace(for target: Window) -> SpaceID? {
    switch Config.current.window.origin {
    case .focused: return SpaceManager.shared.currentSpaceID
    case .cursor: return SpaceID.underCursor
    case .default: return target.id.space
    }
  }

  /// The windows of the AX list of the application that were not known yet.
  func addApplicationWindows(_ owner: Application) -> [Window] {
    guard let windowList = owner.windowList else { return [] }

    var result: [Window] = []

    for windowRef in accessibilityElements(in: windowList) {
      guard let windowID = windowRef.windowID, window(for: windowID) == nil else { continue }

      if let target = createAndAddWindow(
        owner, reference: windowRef, id: windowID, includingOneShotRules: true)
      {
        result.append(target)
      }
    }

    removeOneShotRules()

    return result
  }

  /// The windows on Mission Control spaces, minimized ones included; nil when there are none or the window server fails.
  func existingApplicationWindowList(for owner: Application?) -> [WindowID]? {
    let spaceList = SpaceID.all
    if spaceList.isEmpty { return nil }

    guard
      let candidates = SpaceID.windowCandidates(
        on: spaceList, connection: owner?.connection, includingMinimized: true), !candidates.isEmpty
    else { return nil }
    return SpaceID.userWindows(among: candidates, includingMinimized: true)
  }

  /// The windows in the list that the window manager does not know.
  func unresolvedWindows(in windowList: [WindowID]) -> Set<WindowID> {
    return Set(windowList.filter { window(for: $0) == nil })
  }

  // NOTE: macOS does not return AXUIElementRefs for windows on inactive spaces. Brute-force the element ids
  // to create the AXUIElementRefs ourselves. Every found window is removed from the unresolved set.
  // Attribution: https://github.com/decodism
  // https://github.com/lwouis/alt-tab-macos/issues/1324#issuecomment-2631035482
  private func addWindowsByElementID(for owner: Application, unresolved: inout Set<WindowID>) {
    var data = Data(count: 0x14)
    data.withUnsafeMutableBytes { bytes in
      bytes.storeBytes(of: UInt32(bitPattern: owner.pid), toByteOffset: 0x0, as: UInt32.self)
      bytes.storeBytes(of: UInt32(0x636f_636f), toByteOffset: 0x8, as: UInt32.self)
    }

    for elementID in UInt64(0)..<0x7fff {
      if unresolved.isEmpty { break }

      data.withUnsafeMutableBytes {
        $0.storeBytes(of: elementID, toByteOffset: 0xc, as: UInt64.self)
      }
      guard let element = AXUIElement.element(remoteToken: data) else { continue }

      let (role, error) = element.attributeValue(kAXRoleAttribute)

      // NOTE: An unresponsive application makes each attempt wait for the messaging timeout, so give up on it.
      if error == .cannotComplete { break }

      if let role {
        let elementWid = CFEqual(role, kAXWindowRole as CFString) ? element.windowID : nil

        if let elementWid, unresolved.remove(elementWid) != nil {
          createAndAddWindow(
            owner, reference: element, id: elementWid, includingOneShotRules: false)
        }
      }
    }
  }

  /// Adds the windows of an application. An application in applicationsToRefresh (isRefreshing) leaves the list once
  /// all its windows are resolved; a new application joins it when windows are missing.
  func addExistingApplicationWindows(_ owner: Application, isRefreshing: Bool) {
    guard let globalWindowList = existingApplicationWindowList(for: owner) else { return }

    let windowList = owner.windowList.map { accessibilityElements(in: $0) } ?? []

    var emptyCount = 0
    for windowRef in windowList {
      // NOTE: The AX API appears to always include a Finder element with an empty window id (likely the desktop window).
      // Ignore elements without an id when comparing the discovered and expected window counts.
      guard let windowID = windowRef.windowID else {
        emptyCount += 1
        continue
      }

      if window(for: windowID) == nil {
        createAndAddWindow(owner, reference: windowRef, id: windowID, includingOneShotRules: false)
      }
    }

    var resolved = globalWindowList.count == windowList.count - emptyCount
    if !resolved {
      var unresolved = unresolvedWindows(in: globalWindowList)
      resolved = unresolved.isEmpty

      if !resolved && !isRefreshing {
        Logger.windows.debug(
          "\(owner.name) has \(unresolved.count) windows that are not yet resolved, attempting workaround"
        )
        addWindowsByElementID(for: owner, unresolved: &unresolved)

        if !unresolved.isEmpty {
          Logger.windows.debug("workaround failed to resolve all windows for \(owner.name)")
          applicationsToRefresh.append(owner)
        } else {
          Logger.windows.debug("workaround resolved all windows for \(owner.name)")
        }

        return
      }
    }

    guard resolved, isRefreshing else { return }

    Logger.windows.debug("all windows for \(owner.name) are now resolved")
    applicationsToRefresh.remove(owner)
  }

  private func accessibilityElements(in list: CFArray) -> [AXUIElement] {
    return (0..<CFArrayGetCount(list)).compactMap { index -> AXUIElement? in
      guard let item = CFArrayGetValueAtIndex(list, index) else { return nil }
      return castAttribute(
        Unmanaged<CFTypeRef>.fromOpaque(item).takeUnretainedValue(), typeID: AXUIElementGetTypeID())
    }
  }

  private func debugWindowInfo(_ target: Window) {
    let info = target.info(Set(WindowInfo.Key.allCases))
    let json =
      (try? JSON.encode(info)).map { String(decoding: $0, as: UTF8.self) } ?? "<not encodable>"
    Logger.windows.debug("window info: \(json)")
  }
}
