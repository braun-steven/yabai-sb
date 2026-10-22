import CoreGraphics
import Darwin
import AppKit
import CPrivate
import YabaiCore

//
// NOTE: The query response values of displays, spaces, windows and the tree, read from the managers. Only the values
// of selected properties are queried, because some of them are slow (AX) calls.
//

// MARK: Displays

extension DisplayID
{
    /// The display for `query --displays`.
    @WM func info(_ properties: Set<DisplayInfo.Key>) -> DisplayInfo
    {
        let dm = DisplayManager.shared
        var info = DisplayInfo(id: self, properties: properties)

        if properties.contains(.uuid)     { info.uuid     = uuid ?? "<unknown>" }
        if properties.contains(.index)    { info.index    = arrangement }
        if properties.contains(.label)    { info.label    = dm.labels.name(of: self) ?? "" }
        if properties.contains(.frame)    { info.frame    = QueryFrame(CGDisplayBounds(rawValue)) }
        if properties.contains(.spaces)   { info.spaces   = spaceIndices }
        if properties.contains(.hasFocus) { info.hasFocus = self == dm.currentDisplayID }

        return info
    }

    // NOTE: The Mission Control indices of the spaces of a display.
    @WM private var spaceIndices: [Int]
    {
        guard let spaceList = spaces, let first = spaceList.first?.missionControlIndex else { return [] }
        return (0..<spaceList.count).map { first + $0 }
    }
}

// MARK: Spaces

extension View
{
    /// The space for `query --spaces`.
    func info(_ properties: Set<SpaceInfo.Key>) -> SpaceInfo
    {
        let sm = SpaceManager.shared
        var info = SpaceInfo(id: sid, properties: properties)

        if properties.contains(.uuid)         { info.uuid         = uuid.map { $0 as String } ?? "<unknown>" }
        if properties.contains(.index)        { info.index        = sid.missionControlIndex }
        if properties.contains(.label)        { info.label        = sm.labels.name(of: sid) ?? "" }
        if properties.contains(.type)         { info.type         = layout.rawValue }
        if properties.contains(.display)      { info.display      = sid.display.map { $0.arrangement } ?? 0 }
        if properties.contains(.windows)      { info.windows      = sid.windows(includingMinimized: true) ?? [] }
        if properties.contains(.firstWindow)  { info.firstWindow  = tree?.firstLeaf?.focusedDescendant.windowID }
        if properties.contains(.lastWindow)   { info.lastWindow   = tree?.lastLeaf?.windowID }
        if properties.contains(.hasFocus)     { info.hasFocus     = sid == sm.currentSpaceID }
        if properties.contains(.isVisible)    { info.isVisible    = sid.isVisible }
        if properties.contains(.isFullscreen) { info.isFullscreen = sid.isFullscreen }

        return info
    }
}

extension SpaceManager
{
    // NOTE: Spaces that have no view are left out.
    /// The spaces of the list for `query --spaces`.
    func spaceInfos(_ spaceList: [SpaceID], _ properties: Set<SpaceInfo.Key>) -> [SpaceInfo]
    {
        spaceList.compactMap { queryView(for: $0)?.info(properties) }
    }
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

extension WindowInfo
{
    private func wants(_ keys: Set<Key>) -> Bool
    {
        !properties.isDisjoint(with: keys)
    }

    // NOTE: Without a space (or a display of it), the printed values are 0, as the arrangement and index of no display and no space.
    @WM fileprivate mutating func setSpace(_ sid: SpaceID?)
    {
        if wants([.display]) { display = sid.flatMap { $0.display }.map { $0.arrangement } ?? 0 }
        if wants([.space])   { space   = sid.map { $0.missionControlIndex } ?? 0 }
    }

    fileprivate mutating func setLevels(_ wid: WindowID)
    {
        if wants([.level, .layer])       { level     = wid.level }
        if wants([.subLevel, .subLayer]) { subLevel  = wid.subLevel }
        if wants([.layer])               { layer     = layerName(level) }
        if wants([.subLayer])            { subLayer  = layerName(subLevel) }
        if wants([.opacity])             { opacity   = wid.opacity }
        if wants([.hasShadow])           { hasShadow = wid.hasShadow }
    }

    /// The split, stack index and zoom of the container of a managed window.
    @WM mutating func setTree(_ node: Con?)
    {
        guard let node else { return }

        if let parent = node.parent {
            if parent.layout == .splitH { split = .y }
            if parent.layout == .splitV { split = .x }
        }

        var tab = node
        while let parent = tab.parent, parent.layout != .tabbed { tab = parent }
        stackIndex = tab.index.map { $0 + 1 } ?? 0

        hasParentZoom = node.zoom == .parent
        hasFullscreenZoom = node.zoom == .fullscreen
    }
}

extension Window
{
    /// The window for `query --windows`.
    func info(_ properties: Set<WindowInfo.Key>) -> WindowInfo
    {
        let wm = WindowManager.shared
        let application = self.application!

        var info = WindowInfo(id: id, properties: properties)
        info.pid              = application.pid
        info.app              = application.name
        info.scratchpad       = scratchpad ?? ""
        info.frame            = frame
        info.isRoot           = isRoot
        info.hasFocus         = id == wm.focus.focused
        info.hasAXReference   = true
        info.isFullscreen     = isFullscreen
        info.isMinimized      = isMinimized
        info.isHidden         = application.isHidden
        info.isFloating       = isFloating
        info.isGrabbed        = self == MouseState.shared.window

        if properties.contains(.title)     { info.title     = cachedTitle }
        if properties.contains(.role)      { info.role      = roleString }
        if properties.contains(.subrole)   { info.subrole   = subroleString }
        if properties.contains(.canMove)   { info.canMove   = canMove }
        if properties.contains(.canResize) { info.canResize = canResize }
        info.setLevels(id)

        var sid: SpaceID?
        if !properties.isDisjoint(with: [.display, .space, .isVisible]) {
            sid = id.space
            info.setSpace(sid)
        }

        if !properties.isDisjoint(with: [.splitType, .stackIndex, .hasParentZoom, .hasFullscreenZoom]) {
            info.setTree(wm.managedView(for: self)?.findWindow(id))
        }

        if !properties.isDisjoint(with: [.isVisible, .isSticky]) {
            info.isSticky = isSticky || id.isSticky
        }

        if properties.contains(.isVisible) {
            info.isVisible = SLS.windowIsOrderedIn(SLS.connection, id) && !info.isMinimized && !info.isHidden && (info.isSticky || (sid.map { $0.isVisible } ?? false))
        }

        return info
    }
}

extension WindowID
{
    // NOTE: Windows that yabai has no AX reference for only report what the window server knows.
    /// A window yabai does not track, for `query --windows`.
    @WM func info(_ properties: Set<WindowInfo.Key>) -> WindowInfo
    {
        var info = WindowInfo(id: self, properties: properties)
        info.app        = ""
        info.scratchpad = ""
        info.role       = ""
        info.subrole    = ""

        if !properties.isDisjoint(with: [.pid, .app]) {
            if let owner = SLS.windowOwner(SLS.connection, self), let pid = SLS.connectionPID(owner) { info.pid = pid }

            if properties.contains(.app) {
                // NOTE: PROC_PIDPATHINFO_MAXSIZE, which Swift does not import
                var name = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                if proc_name(info.pid, &name, UInt32(name.count)) > 0 { info.app = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }
            }
        }

        if properties.contains(.title)      { info.title    = SLS.windowTitle(SLS.connection, self) ?? "" }
        if properties.contains(.frame)      { info.frame    = SLS.windowBounds(SLS.connection, self) ?? .zero }
        if properties.contains(.rootWindow) { info.isRoot   = parent == nil }
        if properties.contains(.isSticky)   { info.isSticky = isSticky }
        info.setLevels(self)

        if !properties.isDisjoint(with: [.display, .space, .isFullscreen]) {
            let sid = space
            info.setSpace(sid)
            if properties.contains(.isFullscreen) { info.isFullscreen = sid.map { $0.isFullscreen } ?? false }
        }

        return info
    }
}

extension WindowManager
{
    /// The windows of the spaces for `query --windows`, tracked or not.
    func windowInfos(on spaceList: [SpaceID], _ properties: Set<WindowInfo.Key>) -> [WindowInfo]
    {
        let windowList = SpaceID.windows(on: spaceList, connection: 0, includingMinimized: true) ?? []
        return windowList.map { wid in window(for: wid)?.info(properties) ?? wid.info(properties) }
    }
}

// MARK: Tree

extension View
{
    //
    // NOTE: The container tree of a space, similar to i3's get_tree. Containers list their children
    // in tab or split order. Spaces without the tree layout have no tree.
    //

    /// The tree for `query --tree`; nil unless the space uses the tree layout.
    func treeNode() -> TreeNode?
    {
        guard layout == .tree else { return nil }
        return treeNode(for: root)
    }

    private func treeNode(for node: Con) -> TreeNode
    {
        let leaf = node.isLeaf
        let parent = node.parent

        return TreeNode(
            type: parent == nil ? .workspace : leaf ? .window : .container,
            layout: leaf ? nil : node.layout.rawValue,
            percent: parent != nil ? node.percent : 1.0,
            window: node.windowID,
            frame: leaf ? frame(for: node) : node.area,
            focused: leaf && node.windowID == WindowManager.shared.focus.focused,
            selected: node.isSelected,
            visible: node.isVisible,
            nodes: node.children.map { treeNode(for: $0) })
    }
}
