import CoreGraphics
import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The json of `query --displays`, `--spaces`, `--windows` and `--tree`, read from the managers.
//

/// The SkyLight connection of the daemon (`g_connection`).
var connection: Int32 { connection_global() }

/// The name of a label of a display or space, escaped for json; "" when it has none.
private func labelJSON<ID>(_ list: LabelList<ID>, _ id: ID) -> String
{
    list.find(id: id).map { JSON.string($0.name) } ?? ""
}

/// A list of ids or indices as a json array, separated by ", ".
private func jsonList<Value: BinaryInteger>(_ values: some Sequence<Value>) -> String
{
    "[" + values.map { String($0) }.joined(separator: ", ") + "]"
}

// MARK: Displays

private func displayUUIDText(_ did: DisplayID) -> String
{
    return did.uuid ?? "<unknown>"
}

//
// NOTE: The Mission Control indices of the spaces of a display.
//

private func displaySpaceIndexList(_ did: DisplayID) -> String
{
    guard let spaceList = did.spaces, spaceList.count > 0 else { return "[]" }

    let first = space_manager_mission_control_index(spaceList[0])
    return jsonList((0..<spaceList.count).map { first + $0 })
}

/// `display_serialize`
func displaySerialize(_ did: DisplayID, _ flags: UInt64) -> String
{
    let dm = DisplayManager.shared
    var json = JSONWriter(flags: flags == 0 ? ~flags : flags)

    json.property(DisplayProperty.id,       "\"id\":\(Int32(bitPattern: did.rawValue))")
    json.property(DisplayProperty.uuid,     "\"uuid\":\"\(displayUUIDText(did))\"")
    json.property(DisplayProperty.index,    "\"index\":\(did.arrangement)")
    json.property(DisplayProperty.label,    "\"label\":\"\(labelJSON(dm.labels, did))\"")
    json.property(DisplayProperty.frame,    "\"frame\":" + JSON.frame(CGDisplayBounds(did.rawValue)))
    json.property(DisplayProperty.spaces,   "\"spaces\":\(displaySpaceIndexList(did))")
    json.property(DisplayProperty.hasFocus, "\"has-focus\":\(JSON.bool(did == dm.currentDisplayID))")

    return json.finish()
}

/// `display_manager_query_displays`
@discardableResult
func displayManagerQueryDisplays(_ rsp: inout Response, _ flags: UInt64) -> Bool
{
    let displays = DisplayID.all.map { displaySerialize($0, flags) }
    rsp.write("[\(displays.joined(separator: ","))]\n")
    return true
}

// MARK: Spaces

private func viewUUID(_ view: View) -> String
{
    guard let uuid = view.uuid else { return "<unknown>" }
    return uuid as String
}

//
// NOTE: The windows of a space.
//

private func viewWindowList(_ sid: SpaceID) -> String
{
    guard let windowList = space_window_list(sid, true) else { return "[]" }
    return jsonList(windowList.map { Int32(bitPattern: $0.rawValue) })
}

private func viewFirstWindow(_ view: View) -> WindowID?
{
    guard let tree = view.tree, let first = tree.firstLeaf?.focusedDescendant else { return nil }
    return first.windowID
}

private func viewLastWindow(_ view: View) -> WindowID?
{
    guard let tree = view.tree, let last = tree.lastLeaf else { return nil }
    return last.windowID
}

/// `view_serialize`
func viewSerialize(_ view: View, _ flags: UInt64) -> String
{
    let sm = space_manager_global()
    let sid = view.sid
    var json = JSONWriter(flags: flags == 0 ? ~flags : flags)

    json.property(SpaceProperty.id,           "\"id\":\(Int64(bitPattern: sid.rawValue))")
    json.property(SpaceProperty.uuid,         "\"uuid\":\"\(viewUUID(view))\"")
    json.property(SpaceProperty.index,        "\"index\":\(space_manager_mission_control_index(sid))")
    json.property(SpaceProperty.label,        "\"label\":\"\(labelJSON(sm.labels, sid))\"")
    json.property(SpaceProperty.type,         "\"type\":\"\(view.layout.rawValue)\"")
    json.property(SpaceProperty.display,      "\"display\":\(space_display_id(sid).map { $0.arrangement } ?? 0)")
    json.property(SpaceProperty.windows,      "\"windows\":\(viewWindowList(sid))")
    json.property(SpaceProperty.firstWindow,  "\"first-window\":\(Int32(bitPattern: viewFirstWindow(view)?.rawValue ?? 0))")
    json.property(SpaceProperty.lastWindow,   "\"last-window\":\(Int32(bitPattern: viewLastWindow(view)?.rawValue ?? 0))")
    json.property(SpaceProperty.hasFocus,     "\"has-focus\":\(JSON.bool(sid == sm.current_space_id))")
    json.property(SpaceProperty.isVisible,    "\"is-visible\":\(JSON.bool(space_is_visible(sid)))")
    json.property(SpaceProperty.isFullscreen, "\"is-native-fullscreen\":\(JSON.bool(space_is_fullscreen(sid)))")

    return json.finish()
}

/// `space_manager_query_space`
func spaceManagerQuerySpace(_ rsp: inout Response, _ sid: SpaceID, _ flags: UInt64) -> Bool
{
    guard let view = space_manager_query_view(space_manager_global(), sid) else { return false }

    rsp.write("\(viewSerialize(view, flags))\n")
    return true
}

//
// NOTE: Spaces that have no view are left out, so the separators are written before each element.
//

private func spaceManagerQuerySpaceList(_ rsp: inout Response, _ spaceList: [SpaceID], _ flags: UInt64)
{
    let sm = space_manager_global()
    let spaces = spaceList.compactMap { sid in space_manager_query_view(sm, sid).map { viewSerialize($0, flags) } }
    rsp.write("[\(spaces.joined(separator: ","))]\n")
}

/// `space_manager_query_spaces_for_window`
@discardableResult
func spaceManagerQuerySpacesForWindow(_ rsp: inout Response, _ window: Window, _ flags: UInt64) -> Bool
{
    let spaceList = window.id.spaces
    if spaceList.isEmpty { return false }

    spaceManagerQuerySpaceList(&rsp, spaceList, flags)
    return true
}

/// `space_manager_query_spaces_for_display`
func spaceManagerQuerySpacesForDisplay(_ rsp: inout Response, _ did: DisplayID, _ flags: UInt64) -> Bool
{
    guard let spaceList = did.spaces else { return false }

    spaceManagerQuerySpaceList(&rsp, spaceList, flags)
    return true
}

/// `space_manager_query_spaces_for_displays`
func spaceManagerQuerySpacesForDisplays(_ rsp: inout Response, _ flags: UInt64) -> Bool
{
    guard let spaceList = space_manager_mission_control_space_list() else { return false }

    spaceManagerQuerySpaceList(&rsp, spaceList, flags)
    return true
}

// MARK: Windows

/// `window_layer`: the name of a window level.
private func layerName(_ level: Int32) -> String
{
    if level == CGWindowLevelForKey(.backstopMenu) { return WindowLayer.below.rawValue }
    if level == CGWindowLevelForKey(.normalWindow) { return WindowLayer.normal.rawValue }
    if level == CGWindowLevelForKey(.floatingWindow) { return WindowLayer.above.rawValue }
    return "unknown"
}

private func wanted(_ flags: UInt64, _ properties: UInt64) -> Bool
{
    flags & properties != 0
}

// NOTE: Without a space (or a display of it), the printed values are 0, as the arrangement and index of no display and no space.
private func windowInfoSetSpace(_ info: inout WindowInfo, _ sid: SpaceID?, _ flags: UInt64)
{
    if wanted(flags, WindowProperty.display) { info.display = sid.flatMap { space_display_id($0) }.map { $0.arrangement } ?? 0 }
    if wanted(flags, WindowProperty.space)   { info.space   = sid.map { space_manager_mission_control_index($0) } ?? 0 }
}

private func windowInfoSetLevels(_ info: inout WindowInfo, _ wid: WindowID, _ flags: UInt64)
{
    if wanted(flags, WindowProperty.level | WindowProperty.layer)         { info.level     = wid.level }
    if wanted(flags, WindowProperty.subLevel | WindowProperty.subLayer)   { info.subLevel  = wid.subLevel }
    if wanted(flags, WindowProperty.opacity)                              { info.opacity   = wid.opacity }
    if wanted(flags, WindowProperty.hasShadow)                            { info.hasShadow = wid.hasShadow }
}

/// `window_info_set_tree`: the split, stack index and zoom of the container of a managed window.
func windowInfoSetTree(_ info: inout WindowInfo, _ node: Con?)
{
    guard let node else { return }

    if let parent = node.parent {
        if parent.layout == .splitH { info.split = .y }
        if parent.layout == .splitV { info.split = .x }
    }

    var tab = node
    while let parent = tab.parent, parent.layout != .tabbed { tab = parent }
    info.stackIndex = tab.index.map { $0 + 1 } ?? 0

    info.hasParentZoom = node.zoom == .parent
    info.hasFullscreenZoom = node.zoom == .fullscreen
}

//
// NOTE: Only the properties selected by flags are queried, because some of them are slow (AX) calls.
//

/// `window_info_for_window`
func windowInfo(for window: Window, _ flags: UInt64) -> WindowInfo
{
    let wm = WindowManager.shared
    let application = window.application!
    let wid = window.id

    var info = WindowInfo(id: wid)
    info.pid              = application.pid
    info.app              = application.name
    info.scratchpad       = window.scratchpad ?? ""
    info.frame            = window.frame
    info.isRoot           = window.isRoot
    info.hasFocus         = wid == wm.focusedWindowID
    info.hasAXReference   = true
    info.isFullscreen     = window.isFullscreen
    info.isMinimized      = window.isMinimized
    info.isHidden         = application.isHidden
    info.isFloating       = window.isFloating
    info.isGrabbed        = window == mouse_state_global().window

    if wanted(flags, WindowProperty.title)     { info.title     = window.cachedTitle }
    if wanted(flags, WindowProperty.role)      { info.role      = window.roleString }
    if wanted(flags, WindowProperty.subrole)   { info.subrole   = window.subroleString }
    if wanted(flags, WindowProperty.canMove)   { info.canMove   = window.canMove }
    if wanted(flags, WindowProperty.canResize) { info.canResize = window.canResize }
    windowInfoSetLevels(&info, wid, flags)

    var sid: SpaceID?
    if wanted(flags, WindowProperty.display | WindowProperty.space | WindowProperty.isVisible) {
        sid = wid.space
        windowInfoSetSpace(&info, sid, flags)
    }

    if wanted(flags, WindowProperty.splitType | WindowProperty.stackIndex | WindowProperty.hasParentZoom | WindowProperty.hasFullscreenZoom) {
        let view = wm.managedView(for: window)
        windowInfoSetTree(&info, view?.findWindow(wid))
    }

    if wanted(flags, WindowProperty.isVisible | WindowProperty.isSticky) {
        info.isSticky = window.isSticky || wid.isSticky
    }

    if wanted(flags, WindowProperty.isVisible) {
        info.isVisible = SLS.windowIsOrderedIn(connection, wid) && !info.isMinimized && !info.isHidden && (info.isSticky || (sid.map { space_is_visible($0) } ?? false))
    }

    return info
}

//
// NOTE: Windows that yabai has no AX reference for only report what the window server knows.
//

/// `window_info_for_window_id`
func windowInfo(forID wid: WindowID, _ flags: UInt64) -> WindowInfo
{
    var info = WindowInfo(id: wid)
    info.app        = ""
    info.scratchpad = ""
    info.role       = ""
    info.subrole    = ""

    if wanted(flags, WindowProperty.pid | WindowProperty.app) {
        if let owner = SLS.windowOwner(connection, wid), let pid = SLS.connectionPID(owner) { info.pid = pid }

        if wanted(flags, WindowProperty.app) {
            // NOTE: PROC_PIDPATHINFO_MAXSIZE, which Swift does not import
            var name = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_name(info.pid, &name, UInt32(name.count)) > 0 { info.app = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }
        }
    }

    if wanted(flags, WindowProperty.title)      { info.title    = SLS.windowTitle(connection, wid) ?? "" }
    if wanted(flags, WindowProperty.frame)      { info.frame    = SLS.windowBounds(connection, wid) ?? .zero }
    if wanted(flags, WindowProperty.rootWindow) { info.isRoot   = wid.parent == nil }
    if wanted(flags, WindowProperty.isSticky)   { info.isSticky = wid.isSticky }
    windowInfoSetLevels(&info, wid, flags)

    if wanted(flags, WindowProperty.display | WindowProperty.space | WindowProperty.isFullscreen) {
        let sid = wid.space
        windowInfoSetSpace(&info, sid, flags)
        if wanted(flags, WindowProperty.isFullscreen) { info.isFullscreen = sid.map { space_is_fullscreen($0) } ?? false }
    }

    return info
}

/// `window_serialize`
func windowSerialize(_ window: Window, _ flags: UInt64) -> String
{
    let flags = flags == 0 ? ~flags : flags
    return windowInfo(for: window, flags).serialize(flags, layer: layerName)
}

/// `window_nonax_serialize`
func windowNonAXSerialize(_ wid: WindowID, _ flags: UInt64) -> String
{
    let flags = flags == 0 ? ~flags : flags
    return windowInfo(forID: wid, flags).serialize(flags, layer: layerName)
}

/// `window_manager_query_windows_for_spaces`
func windowManagerQueryWindowsForSpaces(_ rsp: inout Response, _ spaceList: [SpaceID], _ flags: UInt64)
{
    let wm = WindowManager.shared

    let windowList = space_window_list_for_connection(spaceList, 0, true) ?? []

    let windows = windowList.map { wid in
        if let window = wm.window(for: wid) { return windowSerialize(window, flags) }
        return windowNonAXSerialize(wid, flags)
    }

    rsp.write("[\(windows.joined(separator: ","))]\n")
}

/// `window_manager_query_windows_for_display`
func windowManagerQueryWindowsForDisplay(_ rsp: inout Response, _ did: DisplayID, _ flags: UInt64)
{
    windowManagerQueryWindowsForSpaces(&rsp, did.spaces ?? [], flags)
}

/// `window_manager_query_windows_for_displays`
func windowManagerQueryWindowsForDisplays(_ rsp: inout Response, _ flags: UInt64)
{
    windowManagerQueryWindowsForSpaces(&rsp, space_manager_mission_control_space_list() ?? [], flags)
}

// MARK: Tree

private func treeSerializeCon(_ output: inout String, _ view: View, _ node: Con, _ depth: Int)
{
    let leaf = node.isLeaf
    let frame = leaf ? view.frame(for: node) : node.area
    let visible = node.isVisible
    let parent = node.parent

    let type = parent == nil ? "workspace" : leaf ? "window" : "container"
    let layout = leaf ? "null" : "\"\(node.layout.rawValue)\""
    let percent = parent != nil ? node.percent : 1.0
    let focused = leaf && node.windowID == WindowManager.shared.focusedWindowID

    output += String(repeating: " ", count: depth)
    output += "{\"type\":\"\(type)\",\"layout\":\(layout),\"percent\":\(JSON.number(Double(percent))),\"window\":\(Int32(bitPattern: node.windowID?.rawValue ?? 0))"
    output += ",\"frame\":{\"x\":\(JSON.number(Double(frame.x))),\"y\":\(JSON.number(Double(frame.y))),\"w\":\(JSON.number(Double(frame.w))),\"h\":\(JSON.number(Double(frame.h)))}"
    output += ",\"focused\":\(JSON.bool(focused)),\"selected\":\(JSON.bool(node.isSelected)),\"visible\":\(JSON.bool(visible)),\"nodes\":["

    let childCount = node.children.count
    for i in 0..<childCount {
        output += i != 0 ? ",\n" : "\n"
        treeSerializeCon(&output, view, node.children[i], depth + 1)
    }

    output += childCount != 0 ? "\n]}" : "]}"
}

//
// NOTE: The container tree of a space, similar to i3's get_tree. Containers list their children
// in tab or split order. Spaces without the tree layout have no tree.
//

/// `tree_serialize`
func treeSerialize(_ rsp: inout Response, _ view: View) -> Bool
{
    guard view.layout == .tree else { return false }

    var output = ""
    treeSerializeCon(&output, view, view.root, 0)
    rsp.write("\(output)\n")
    return true
}
