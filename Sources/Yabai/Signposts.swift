import os

/// Signpost intervals for Instruments (the Logging template or the os_signpost instrument, subsystem com.asmvik.yabai):
/// one per event the event loop handles, named after its case, and one per animation run and per animation frame.
enum Signposts {
  //
  // NOTE: The subsystem is the launchd label of the service (Service.swift), since the daemon has no os_log subsystem of
  // its own. Without a recording, a begin or end costs one check of the signposter; keep the names StaticStrings.
  //
  static let events = OSSignposter(subsystem: "com.asmvik.yabai", category: "events")
  static let animation = OSSignposter(subsystem: "com.asmvik.yabai", category: "animation")
}

extension Event {
  /// The name of the signpost interval of this event.
  var signpostName: StaticString {
    switch self {
    case .carbonProcessLaunched: "carbonProcessLaunched"
    case .carbonProcessTerminated: "carbonProcessTerminated"
    case .carbonProcessFrontSwitched: "carbonProcessFrontSwitched"
    case .applicationLaunchRetry: "applicationLaunchRetry"
    case .applicationLaunched: "applicationLaunched"
    case .applicationTerminated: "applicationTerminated"
    case .applicationFrontSwitched: "applicationFrontSwitched"
    case .applicationVisible: "applicationVisible"
    case .applicationHidden: "applicationHidden"
    case .windowCreated: "windowCreated"
    case .windowDestroyed: "windowDestroyed"
    case .windowFocused: "windowFocused"
    case .windowFocusDeferred: "windowFocusDeferred"
    case .windowMoved: "windowMoved"
    case .windowResized: "windowResized"
    case .windowMinimized: "windowMinimized"
    case .windowDeminimized: "windowDeminimized"
    case .windowTitleChanged: "windowTitleChanged"
    case .slsWindowOrdered: "slsWindowOrdered"
    case .slsWindowDestroyed: "slsWindowDestroyed"
    case .slsSpaceCreated: "slsSpaceCreated"
    case .slsSpaceDestroyed: "slsSpaceDestroyed"
    case .spaceChanged: "spaceChanged"
    case .displayAdded: "displayAdded"
    case .displayRemoved: "displayRemoved"
    case .displayMoved: "displayMoved"
    case .displayResized: "displayResized"
    case .displayChanged: "displayChanged"
    case .mouseDown: "mouseDown"
    case .mouseUp: "mouseUp"
    case .mouseDragged: "mouseDragged"
    case .mouseMoved: "mouseMoved"
    case .splitDragBegan: "splitDragBegan"
    case .splitDragMoved: "splitDragMoved"
    case .splitDragEnded: "splitDragEnded"
    case .tabBarClicked: "tabBarClicked"
    case .tabCardOrdered: "tabCardOrdered"
    case .missionControlShowAllWindows: "missionControlShowAllWindows"
    case .missionControlShowFrontWindows: "missionControlShowFrontWindows"
    case .missionControlShowDesktop: "missionControlShowDesktop"
    case .missionControlEnter: "missionControlEnter"
    case .missionControlCheckForExit: "missionControlCheckForExit"
    case .missionControlExit: "missionControlExit"
    case .dockDidRestart: "dockDidRestart"
    case .menuOpened: "menuOpened"
    case .menuClosed: "menuClosed"
    case .menuBarHiddenChanged: "menuBarHiddenChanged"
    case .dockDidChangePref: "dockDidChangePref"
    case .systemWoke: "systemWoke"
    case .configChanged: "configChanged"
    case .configFileChanged: "configFileChanged"
    case .configLoaded: "configLoaded"
    case .scriptingAdditionLoaded: "scriptingAdditionLoaded"
    case .spaceLayoutReconcile: "spaceLayoutReconcile"
    case .spacePinReconcile: "spacePinReconcile"
    case .focusClickCursorRestore: "focusClickCursorRestore"
    case .spaceMoveFocusCheck: "spaceMoveFocusCheck"
    case .spaceMoveRefreshCheck: "spaceMoveRefreshCheck"
    case .displaySpacesRefresh: "displaySpacesRefresh"
    case .daemonMessage: "daemonMessage"
    case .eventSubscriberRemoved: "eventSubscriberRemoved"
    }
  }
}
