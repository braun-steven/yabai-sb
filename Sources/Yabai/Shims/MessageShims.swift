import AppKit
import CPrivate
import YabaiCore

//
// NOTE: What the handlers of the IPC domains (Sources/Yabai/IPC/) need from the managers: the selectors look up
// displays, spaces and windows in them.
//

extension Token
{
    init(cString: UnsafePointer<CChar>?)
    {
        guard let cString else {
            self.init(ArraySlice<UInt8>())
            return
        }

        self.init(UnsafeRawBufferPointer(start: cString, count: strlen(cString)))
    }
}

/// A malloc'ed copy of bytes with a null terminator, which the C code frees.
func mallocString(_ bytes: some Collection<UInt8>) -> UnsafeMutablePointer<CChar>
{
    let result = malloc(bytes.count + 1)!.bindMemory(to: CChar.self, capacity: bytes.count + 1)
    for (i, byte) in bytes.enumerated() { result[i] = CChar(bitPattern: byte) }
    result[bytes.count] = 0
    return result
}

func mallocString(_ string: String?) -> UnsafeMutablePointer<CChar>?
{
    string.map { mallocString($0.utf8) }
}

/// The selectors look up displays, spaces and windows in the managers.
struct CSelectorContext: SelectorContext
{
    typealias Window = Yabai.Window

    var activeDisplay: UInt32 { display_manager_active_display_id() }
    var activeSpace: UInt64 { space_manager_active_space() }
    var actingWindow: Window? { window_manager_acting_window(window_manager_global()) }

    func display(_ query: DisplayQuery) -> UInt32
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

    func displayLabel(_ label: Token) -> UInt64?
    {
        display_manager_global().labels.find(name: label.string)?.id
    }

    func space(_ query: SpaceQuery) -> UInt64
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

    func spaceLabel(_ label: Token) -> UInt64?
    {
        space_manager_global().labels.find(name: label.string)?.id
    }

    func window(_ query: WindowQuery<Window>) -> Window?
    {
        switch query {
        case .id(let id):                          window_manager_find_window(window_manager_global(), id)
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
        case .stackPosition(let window, let index): window_manager_find_window_in_stack(space_manager_global(), window_manager_global(), window, index)
        }
    }
}

//
// NOTE: The values of LAYER_* (src/misc/macros.h). Swift does not import the macros that name the CGWindowLevelKey
// constants.
//

func layerValue(_ layer: WindowLayer) -> Int32
{
    switch layer {
    case .auto:   Int32(LAYER_AUTO)
    case .below:  CGWindowLevelKey.backstopMenu.rawValue
    case .normal: CGWindowLevelKey.normalWindow.rawValue
    case .above:  CGWindowLevelKey.floatingWindow.rawValue
    }
}
