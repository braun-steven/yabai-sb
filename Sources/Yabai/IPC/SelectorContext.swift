import CPrivate
import YabaiCore

/// The selectors look up displays, spaces and windows in the managers.
struct CSelectorContext: SelectorContext
{
    typealias Window = Yabai.Window

    var activeDisplay: DisplayID? { DisplayID.active }
    var activeSpace: SpaceID? { space_manager_active_space() }
    var actingWindow: Window? { WindowManager.shared.actingWindow }

    func display(_ query: DisplayQuery) -> DisplayID?
    {
        switch query {
        case .arrangement(let index):         DisplayID(arrangement: index)
        case .inDirection(let direction, let did): did.closestDisplay(in: direction)
        case .prev(let did):                  did.previous
        case .next(let did):                  did.next
        case .first:                          DisplayID.first
        case .last:                           DisplayID.last
        case .recent:                         DisplayManager.shared.lastDisplayID
        case .cursor:                         DisplayID.underCursor
        }
    }

    func displayLabel(_ label: Token) -> DisplayID?
    {
        DisplayManager.shared.labels.find(name: label.string)?.id
    }

    func space(_ query: SpaceQuery) -> SpaceID?
    {
        switch query {
        case .missionControl(let index): space_manager_mission_control_space(index)
        case .prev(let sid):             space_manager_prev_space(sid)
        case .next(let sid):             space_manager_next_space(sid)
        case .first:                     space_manager_first_space()
        case .last:                      space_manager_last_space()
        case .recent:                    space_manager_global().last_space_id
        case .cursor:                    space_manager_cursor_space()
        }
    }

    func spaceLabel(_ label: Token) -> SpaceID?
    {
        space_manager_global().labels.find(name: label.string)?.id
    }

    func window(_ query: WindowQuery<Window>) -> Window?
    {
        switch query {
        case .id(let id):                          WindowManager.shared.window(for: id)
        case .inDirection(let direction, let from): WindowManager.shared.closestManagedWindow(to: from, in: direction)
        case .belowCursor:                         WindowManager.shared.windowBelowCursor()
        case .largest:                             WindowManager.shared.largestManagedWindow()
        case .smallest:                            WindowManager.shared.smallestManagedWindow()
        case .prev(let window):                    WindowManager.shared.previousManagedWindow(from: window)
        case .next(let window):                    WindowManager.shared.nextManagedWindow(from: window)
        case .first:                               WindowManager.shared.firstManagedWindow()
        case .last:                                WindowManager.shared.lastManagedWindow()
        case .recent:                              WindowManager.shared.recentManagedWindow()
        case .stackPrev(let window):               WindowManager.shared.previousWindowInStack(around: window)
        case .stackNext(let window):               WindowManager.shared.nextWindowInStack(around: window)
        case .stackFirst(let window):              WindowManager.shared.firstWindowInStack(around: window)
        case .stackLast(let window):               WindowManager.shared.lastWindowInStack(around: window)
        case .stackRecent(let window):             WindowManager.shared.recentWindowInStack(around: window)
        case .stackPosition(let window, let index): WindowManager.shared.windowInStack(around: window, at: index)
        }
    }
}
