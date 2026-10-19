import CPrivate
import YabaiCore

/// The selectors look up displays, spaces and windows in the managers.
struct CSelectorContext: SelectorContext
{
    typealias Window = Yabai.Window

    var activeDisplay: DisplayID? { display_manager_active_display_id() }
    var activeSpace: SpaceID? { space_manager_active_space() }
    var actingWindow: Window? { window_manager_acting_window(window_manager_global()) }

    func display(_ query: DisplayQuery) -> DisplayID?
    {
        switch query {
        case .arrangement(let index):         display_manager_arrangement_display_id(index)
        case .inDirection(let direction, let did): display_manager_find_closest_display_in_direction(did, direction)
        case .prev(let did):                  display_manager_prev_display_id(did)
        case .next(let did):                  display_manager_next_display_id(did)
        case .first:                          display_manager_first_display_id()
        case .last:                           display_manager_last_display_id()
        case .recent:                         display_manager_global().last_display_id
        case .cursor:                         display_manager_cursor_display_id()
        }
    }

    func displayLabel(_ label: Token) -> DisplayID?
    {
        display_manager_global().labels.find(name: label.string)?.id
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
        case .inDirection(let direction, let from): window_manager_find_closest_managed_window_in_direction(window_manager_global(), from, direction)
        case .belowCursor:                         window_manager_find_window_below_cursor(window_manager_global())
        case .largest:                             window_manager_find_largest_managed_window(space_manager_global(), window_manager_global())
        case .smallest:                            window_manager_find_smallest_managed_window(space_manager_global(), window_manager_global())
        case .prev(let window):                    window_manager_find_prev_managed_window(space_manager_global(), window_manager_global(), window)
        case .next(let window):                    window_manager_find_next_managed_window(space_manager_global(), window_manager_global(), window)
        case .first:                               window_manager_find_first_managed_window(space_manager_global(), window_manager_global())
        case .last:                                window_manager_find_last_managed_window(space_manager_global(), window_manager_global())
        case .recent:                              window_manager_find_recent_managed_window(window_manager_global())
        case .stackPrev(let window):               window_manager_find_prev_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackNext(let window):               window_manager_find_next_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackFirst(let window):              window_manager_find_first_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackLast(let window):               window_manager_find_last_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackRecent(let window):             window_manager_find_recent_window_in_stack(space_manager_global(), window_manager_global(), window)
        case .stackPosition(let window, let index): window_manager_find_window_in_stack(space_manager_global(), WindowManager.shared, window, index)
        }
    }
}
