import Testing
import CoreGraphics
import InlineSnapshotTesting
import PropertyBased
import YabaiCore
@testable import Yabai
import YabaiTestSupport

//
// NOTE: Layout geometry: the areas Con.layOut gives a tree (through View.updateTree, which takes the gap and the tab
// bar from the view and the config), the frames a view flushes (frame(for:) with zoom) and the placements a headless
// flush records. The random trees come from TreeModel (TreePropertyTests.swift).
//

/// The tab bar settings of a layout run, applied to the config.
struct BarSettings: Sendable, CustomStringConvertible
{
    var enabled: Bool
    var height: Int
    var offset: Int
    var style: TabBarStyle
    var backdrop: TabBarBackdrop
    var cardPadding: Int

    static var generator: Generator<BarSettings, some SendableSequenceType>
    {
        zip(Gen.bool, Gen.int(in: 0...40), Gen.int(in: -40...20), Gen.int(in: 0...1), Gen.int(in: 0...2), Gen.int(in: 0...12))
            .map { enabled, height, offset, style, backdrop, cardPadding in
                BarSettings(enabled: enabled, height: height, offset: offset, style: TabBarStyle.allCases[style],
                            backdrop: TabBarBackdrop.allCases[backdrop], cardPadding: cardPadding)
            }
    }

    @WM func apply()
    {
        Config.current.tabBar.enabled = enabled
        Config.current.tabBar.height = height
        Config.current.tabBar.offset = offset
        Config.current.tabBar.style = style
        Config.current.tabBar.backdrop = backdrop
        Config.current.tabBar.cardPadding = cardPadding
    }

    /// The height of the bar the tabs leave room for: none while the bar is off.
    var barHeight: Int { enabled ? height : 0 }

    /// The inset of a glass card with a backdrop from the edges of its container.
    var barInset: Int { barHeight > 0 && style == .glass && backdrop != .off ? cardPadding : 0 }

    var description: String
    {
        "bar \(enabled ? "on" : "off") height \(height) offset \(offset) \(style.rawValue)/\(backdrop.rawValue) padding \(cardPadding)"
    }
}

/// A root area of a layout run, with integral values like a display frame.
struct LayoutArea: Sendable, CustomStringConvertible
{
    var area: Area
    var gap: Int

    static var generator: Generator<LayoutArea, some SendableSequenceType>
    {
        zip(Gen.int(in: -2000...2000), Gen.int(in: 0...1000), Gen.int(in: 600...3000), Gen.int(in: 400...2000), Gen.int(in: 0...20))
            .map { x, y, w, h, gap in LayoutArea(area: Area(x: Float(x), y: Float(y), w: Float(w), h: Float(h)), gap: gap) }
    }

    var description: String { "\(Int(area.x)),\(Int(area.y)) \(Int(area.w))x\(Int(area.h)) gap \(gap)" }
}

/// The broken rules of the areas of a laid-out tree, empty when the layout is consistent.
@WM func layoutViolations(_ root: Con, gap: Int, bar: BarSettings) -> [String]
{
    var result: [String] = []
    layoutViolations(root, in: root.area, gap: Float(gap), bar: bar, into: &result)
    return result
}

@WM private func layoutViolations(_ node: Con, in bounds: Area, gap: Float, bar: BarSettings, into result: inout [String])
{
    let area = node.area
    let name = node.windowID.map { "w\($0.rawValue - treeTestWindowBase)" } ?? node.layout.rawValue

    if area.x < bounds.x || area.y < bounds.y || area.x + area.w > bounds.x + bounds.w || area.y + area.h > bounds.y + bounds.h {
        result.append("\(name) \(area) is outside the root area")
    }
    if node.isLeaf || node.children.isEmpty { return }

    if node.layout == .tabbed {
        // the children share the card frame below the bar, inset from every edge when the card has a backdrop
        var expected = area
        let barHeight = Float(bar.barHeight)
        if barHeight > 0 && area.h > 2 * barHeight {
            let barInset = Float(bar.barInset)
            let inset = barInset > 0 && area.w > 4 * barInset && area.h - 2 * barInset > 2 * barHeight ? barInset : 0
            expected = Area(x: area.x + inset, y: area.y + inset, w: area.w - 2 * inset, h: area.h - 2 * inset)

            let reserve = min(max(barHeight + Float(bar.offset), 0), expected.h - barHeight)
            expected.y += reserve
            expected.h -= reserve
            if expected.h < barHeight { result.append("tabs of \(area) are lower than the bar") }
        }
        for child in node.children where child.area != expected {
            result.append("tab \(child.area) of \(area) instead of \(expected)")
        }
    } else {
        // the children fill the split one gap apart, each in its share, and the last one takes the remainder
        let horizontal = node.layout == .splitH
        func start(_ a: Area) -> Float { horizontal ? a.x : a.y }
        func size(_ a: Area) -> Float { horizontal ? a.w : a.h }
        func cross(_ a: Area) -> (Float, Float) { horizontal ? (a.y, a.h) : (a.x, a.w) }

        // NOTE: A split shorter than its gaps gives its last child a negative length (ISSUES.md 5), so the rules only
        // hold for splits with at least a pixel per child (negativeLengthInASplitShorterThanItsGaps).
        let total = size(area) - gap * Float(node.children.count - 1)
        if total < Float(node.children.count) { return }

        var offset = start(area)
        for (i, child) in node.children.enumerated() {
            let childArea = child.area
            if start(childArea) != offset { result.append("child \(i) of \(area) starts at \(start(childArea)), not \(offset)") }
            if cross(childArea) != cross(area) { result.append("child \(i) \(childArea) leaves the cross axis of \(area)") }
            if i < node.children.count - 1 {
                let share = total * child.percent
                if size(childArea) != size(childArea).rounded() || abs(size(childArea) - share) > 0.5 {
                    result.append("child \(i) of \(area) is \(size(childArea)) long for a share of \(share)")
                }
            } else if start(childArea) + size(childArea) != start(area) + size(area) {
                result.append("the last child \(childArea) does not end with \(area)")
            }
            offset = start(childArea) + size(childArea) + gap
        }
    }

    for child in node.children { layoutViolations(child, in: bounds, gap: gap, bar: bar, into: &result) }
}

/// A placement of a headless flush, with the window named like treeDump does.
struct PlacementLine: CustomStringConvertible
{
    var placement: RecordedPlacement

    var description: String
    {
        let p = placement
        return "w\(p.windowID.rawValue - treeTestWindowBase): \(Int(p.x)),\(Int(p.y)) \(Int(p.w))x\(Int(p.h))"
    }
}

@WM private func drainPlacements() -> [PlacementLine]
{
    Headless.drain().placements.map { PlacementLine(placement: $0) }
}

@WM private func leaves(_ root: Con) -> [Con]
{
    root.windowIDs.map { root.find($0)! }
}

extension DaemonState
{
    @Suite
    @WM struct LayoutTests
    {
        // MARK: - Properties

        /// A random tree laid out in a view with a random area, gap and tab bar.
        private func layOutRandomTree(_ count: Int, _ operations: [TreeOperation], _ geometry: LayoutArea, _ bar: BarSettings) -> (View, TreeModel)
        {
            let model = TreeModel(windowCount: count)
            for operation in operations { model.apply(operation) }
            bar.apply()

            let view = View(sid: Workspace.sid)
            view.layout = .tree
            view.area = geometry.area
            view.windowGap = geometry.gap
            view.isGapEnabled = true
            view.tree = model.root
            view.updateTree()
            return (view, model)
        }

        @Test func layoutFillsTheRootArea() async
        {
            await propertyCheck(count: 300, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 0...30), LayoutArea.generator, BarSettings.generator) { count, operations, geometry, bar in
                let (view, model) = layOutRandomTree(count, operations, geometry, bar)

                #expect(model.root.area == geometry.area)
                let violations = layoutViolations(model.root, gap: geometry.gap, bar: bar)
                try #require(violations.isEmpty, "\(violations)\n\(treeDump(model.root))")
                view.tree = nil
            }
        }

        @Test func zoomedWindowsGetTheFrameOfTheirParentOrTheRoot() async
        {
            await propertyCheck(count: 100, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 0...30), LayoutArea.generator, BarSettings.generator) { count, operations, geometry, bar in
                let (view, model) = layOutRandomTree(count, operations, geometry, bar)

                for leaf in leaves(model.root) {
                    #expect(view.frame(for: leaf) == leaf.area)
                    leaf.zoom = .parent
                    #expect(view.frame(for: leaf) == leaf.parent!.area)
                    leaf.zoom = .fullscreen
                    #expect(view.frame(for: leaf) == geometry.area)
                    leaf.zoom = .none
                }
                view.tree = nil
            }
        }

        @Test func flushPlacesEveryWindowAtItsFrame() async
        {
            await propertyCheck(count: 100, input: Gen.int(in: 1...12), TreeOperation.generator.array(of: 0...30), LayoutArea.generator, Gen.int(in: 0...2)) { count, operations, geometry, zoom in
                let bar = BarSettings(enabled: true, height: 24, offset: 0, style: .glass, backdrop: .blur, cardPadding: 6)
                let (view, model) = layOutRandomTree(count, operations, geometry, bar)
                let all = leaves(model.root)

                // NOTE: A negative length (ISSUES.md 5) is placed again on every flush: CGRect standardizes it.
                if all.contains(where: { $0.area.w < 0 || $0.area.h < 0 }) { return }

                for windowID in model.windows { WindowManager.shared.window[windowID] = Window(id: windowID) }

                let zoomed = all[operations.count % all.count]
                zoomed.zoom = [ConZoom.none, .parent, .fullscreen][zoom]
                _ = Headless.drain()

                view.flush()

                let expected = all.map { leaf in
                    let frame = view.frame(for: leaf)
                    return RecordedPlacement(windowID: leaf.windowID!, x: frame.x, y: frame.y, w: frame.w, h: frame.h)
                }
                #expect(Headless.drain().placements == expected)
                for leaf in all {
                    let frame = WindowManager.shared.window[leaf.windowID!]!.frame
                    #expect(!view.needsFlush(windowID: leaf.windowID!, frame: frame))
                }

                view.flush()
                #expect(Headless.drain().placements.isEmpty)

                for windowID in model.windows { WindowManager.shared.window[windowID] = nil }
                view.tree = nil
            }
        }

        // MARK: - Examples

        @Test func tabbedChildrenShareTheCardBelowTheBar()
        {
            Config.current.tabBar.style = .glass
            Config.current.tabBar.backdrop = .blur
            Config.current.tabBar.cardPadding = 6
            Config.current.tabBar.height = 24
            let root = Con(layout: .tabbed)
            treeTestLeaf(root, wid(1))
            treeTestLeaf(root, wid(2))

            root.layOut(Area(x: 0, y: 0, w: 1000, h: 800), gap: 10, barHeight: 24, barOffset: 0, barInset: 6)
            #expect(root.children.map(\.area) == Array(repeating: Area(x: 6, y: 30, w: 988, h: 764), count: 2))

            // a negative offset reaches under the bar, but no higher than the card
            root.layOut(Area(x: 0, y: 0, w: 1000, h: 800), gap: 10, barHeight: 24, barOffset: -40, barInset: 6)
            #expect(root.children[0].area == Area(x: 6, y: 6, w: 988, h: 788))

            // a large offset leaves the tabs the height of the bar
            root.layOut(Area(x: 0, y: 0, w: 1000, h: 100), gap: 10, barHeight: 24, barOffset: 200, barInset: 6)
            #expect(root.children[0].area == Area(x: 6, y: 70, w: 988, h: 24))

            // no room for the card: the bar sits on the edge of the container
            #expect(Con.cardInset(Area(x: 0, y: 0, w: 1000, h: 60), barHeight: 24, barInset: 6) == 0)
            #expect(Con.cardInset(Area(x: 0, y: 0, w: 24, h: 800), barHeight: 24, barInset: 6) == 0)
            #expect(Con.cardInset(Area(x: 0, y: 0, w: 1000, h: 800), barHeight: 24, barInset: 0) == 0)

            // a container no higher than two bars gives its tabs all of its area
            root.layOut(Area(x: 0, y: 0, w: 1000, h: 48), gap: 10, barHeight: 24, barOffset: 0, barInset: 6)
            #expect(root.children[0].area == Area(x: 0, y: 0, w: 1000, h: 48))
        }

        @Test func lastChildTakesTheRemainder()
        {
            let root = Con(layout: .splitH)
            for n: UInt32 in 1...3 { treeTestLeaf(root, wid(n)) }

            root.layOut(Area(x: 0, y: 0, w: 1001, h: 500), gap: 0, barHeight: 0, barOffset: 0, barInset: 0)
            #expect(root.children.map(\.area.w) == [334, 334, 333])

            root.layOut(Area(x: 10, y: 0, w: 1000, h: 500), gap: 7, barHeight: 0, barOffset: 0, barInset: 0)
            #expect(root.children.map(\.area.x) == [10, 346, 682])
            #expect(root.children.map(\.area.w) == [329, 329, 328])
        }

        @Test func negativeLengthInASplitShorterThanItsGaps()
        {
            let root = Con(layout: .splitV)
            for n: UInt32 in 1...3 { treeTestLeaf(root, wid(n)) }

            root.layOut(Area(x: 0, y: 0, w: 300, h: 22), gap: 12, barHeight: 0, barOffset: 0, barInset: 0)
            #expect(root.children.map(\.area.y) == [0, 12, 24])

            withKnownIssue("ISSUES.md 5: the last child of a split shorter than its gaps gets a negative length") {
                #expect(root.children.allSatisfy { $0.area.h >= 0 }, "\(root.children.map(\.area.h))")
            }
        }

        @Test(arguments: [
            (CGRect(x: 0, y: 0, width: 600, height: 800), false),
            (CGRect(x: 1.4, y: -1.4, width: 601.4, height: 798.6), false),
            (CGRect(x: 1.5, y: 0, width: 600, height: 800), true),
            (CGRect(x: 0, y: -1.5, width: 600, height: 800), true),
            (CGRect(x: 0, y: 0, width: 598.5, height: 800), true),
            (CGRect(x: 0, y: 0, width: 600, height: 801.5), true),
        ])
        func needsFlushAtOnePointFivePixels(frame: CGRect, needsFlush: Bool)
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)

            #expect(space.view.needsFlush(windowID: wid(1), frame: frame) == needsFlush)
            #expect(!space.view.needsFlush(windowID: wid(9), frame: .zero))
        }

        @Test func needsFlushFollowsTheZoom()
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            let full = CGRect(x: 0, y: 0, width: 1200, height: 800)

            #expect(space.view.needsFlush(windowID: wid(1), frame: full))
            space.node(1).zoom = .fullscreen
            #expect(!space.view.needsFlush(windowID: wid(1), frame: full))
            space.node(1).zoom = .parent
            #expect(!space.view.needsFlush(windowID: wid(1), frame: full))
        }

        // MARK: - View

        @Test(arguments: ViewSpacing.allCases)
        func spacingNamesItsValueAndOverride(_ spacing: ViewSpacing)
        {
            let view = View(sid: Workspace.sid)
            view[keyPath: spacing.view] = 17

            let values = [view.topPadding, view.bottomPadding, view.leftPadding, view.rightPadding, view.windowGap]
            #expect(values.filter { $0 == 17 }.count == 1)
            #expect(ViewSpacing.allCases.filter { $0.override == spacing.override }.count == 1)
        }

        @Test func clearEmptiesTheViewAndLaysItOutAgain()
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.view.insertionPoint = wid(1)

            space.view.clear()

            #expect(space.view.tree == nil)
            #expect(space.view.insertionPoint == nil)
            #expect(WindowManager.shared.managedWindows.isEmpty)
            #expect(space.view.area == Area(Headless.displayFrame))
            #expect(space.view.isValid && !space.view.isInvalid)
        }

        // MARK: - Borders and tab order

        @Test func borderWrapsTheTabbedContainerOfTheActiveTab()
        {
            Config.current.tabBar.style = .glass
            Config.current.tabBar.backdrop = .blur
            Config.current.tabBar.cardPadding = 6
            Config.current.tabBar.windowRadius = 16
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.view.insertionPoint = wid(2)
            space.node(2).insertDirection = .stack
            space.open(3, focus: true)
            let tabs = space.node(3).parent!

            let active = space.view.borderArea(windowID: wid(3))
            #expect(active.visible)
            #expect(active.window == space.node(3).area)
            #expect(active.border == tabs.area)
            #expect(active.radius == 16 + 6)

            #expect(!space.view.borderArea(windowID: wid(2)).visible)

            let split = space.view.borderArea(windowID: wid(1))
            #expect(split == (true, space.node(1).area, space.node(1).area, 0))

            let outside = space.view.borderArea(windowID: wid(9))
            #expect(outside == (true, .zero, .zero, 0))

            // without a backdrop the border keeps the radius of the window
            Config.current.tabBar.backdrop = .off
            space.view.updateTree()
            #expect(space.view.borderArea(windowID: wid(3)).radius == 0)

            // a zoomed window hides the bar, so the border wraps the window alone
            space.node(3).zoom = .parent
            #expect(space.view.borderArea(windowID: wid(3)).border == space.node(3).area)
        }

        @Test func tabOrderPutsHiddenTabsBelowTheActiveOne()
        {
            let space = Workspace()
            space.open(1, focus: true)
            space.node(1).setLayout(.tabbed)
            space.open(2, focus: true)
            space.open(3, focus: true)
            let root = space.view.root

            var list: [WindowOrder] = []
            root.collectTabOrder(force: false, into: &list)
            #expect(list == [
                WindowOrder(window: wid(1), order: -1, relativeTo: wid(3)),
                WindowOrder(window: wid(2), order: -1, relativeTo: wid(3)),
            ])

            // nothing changed since: no orders, unless forced
            list = []
            root.collectTabOrder(force: false, into: &list)
            #expect(list.isEmpty)
            root.collectTabOrder(force: true, into: &list)
            #expect(list.count == 2)

            // a split tab keeps its other windows above the focused one
            space.focus(1)
            space.node(1).split(.vertical)
            treeTestLeaf(space.node(1).parent!, wid(4))
            list = []
            root.collectTabOrder(force: false, into: &list)
            #expect(list.contains(WindowOrder(window: wid(4), order: 1, relativeTo: wid(1))))

            list = []
            root.collectCardOrder(after: wid(1), into: &list)
            #expect(list == [WindowOrder(window: wid(4), order: 1, relativeTo: wid(1))])

            // raiseTabs sends the orders to the payload in one message
            _ = Headless.drain()
            root.raiseTabs(force: true)
            #expect(Headless.drain().messages.count == 1)
        }

        // MARK: - Placement snapshots

        /// A view of the headless display with the given padding and gap.
        private func paddedWorkspace(padding: Int = 0, gap: Int = 0) -> Workspace
        {
            let space = Workspace()
            let view = space.view
            view.isPaddingEnabled = true
            view.isGapEnabled = true
            (view.topPadding, view.bottomPadding, view.leftPadding, view.rightPadding) = (padding, padding, padding, padding)
            view.windowGap = gap
            view.update()
            return space
        }

        private func flush(_ space: Workspace) -> [PlacementLine]
        {
            _ = Headless.drain()
            space.view.updateAndFlush()
            return drainPlacements()
        }

        @Test func halves()
        {
            let space = paddedWorkspace()
            space.open(1, focus: true)
            space.open(2, focus: true)

            assertInlineSnapshot(of: flush(space), as: .descriptionLines) {
                """
                w1: 0,0 720x900
                w2: 720,0 720x900
                """
            }
        }

        @Test func threeWaysWithGaps()
        {
            let space = paddedWorkspace(gap: 10)
            for n: UInt32 in 1...3 { space.open(n, focus: true) }

            assertInlineSnapshot(of: flush(space), as: .descriptionLines) {
                """
                w1: 0,0 473x900
                w2: 483,0 473x900
                w3: 966,0 474x900
                """
            }
        }

        @Test func nestedSplits()
        {
            let space = paddedWorkspace(padding: 12, gap: 8)
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.node(2).split(.vertical)
            space.open(3, focus: true)
            space.node(3).split(.horizontal)
            space.open(4, focus: true)

            assertInlineSnapshot(of: treeDump(space.view.root), as: .lines) {
                """
                splith focus=1,0
                  w1 0.5000
                  splitv 0.5000 focus=1,0
                    w2 0.5000
                    splith 0.5000 focus=1,0
                      w3 0.5000
                      w4 0.5000
                """
            }
            assertInlineSnapshot(of: flush(space), as: .descriptionLines) {
                """
                w1: 12,12 704x876
                w2: 724,12 704x434
                w3: 724,454 348x434
                w4: 1080,454 348x434
                """
            }
        }

        @Test func tabbedWithGlassCard()
        {
            Config.current.tabBar.style = .glass
            Config.current.tabBar.backdrop = .blur
            Config.current.tabBar.cardPadding = 6
            Config.current.tabBar.height = 24
            let space = paddedWorkspace(padding: 10, gap: 10)
            space.open(1, focus: true)
            space.node(1).setLayout(.tabbed)
            space.open(2, focus: true)
            space.open(3, focus: true)

            assertInlineSnapshot(of: flush(space), as: .descriptionLines) {
                """
                w1: 16,40 1408x844
                w2: 16,40 1408x844
                w3: 16,40 1408x844
                """
            }
        }

        @Test func stackedWithPadding()
        {
            Config.current.tabBar.style = .i3
            Config.current.tabBar.height = 24
            let space = paddedWorkspace(padding: 20, gap: 10)
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.view.insertionPoint = wid(2)
            space.node(2).insertDirection = .stack
            space.open(3, focus: true)

            assertInlineSnapshot(of: treeDump(space.view.root), as: .lines) {
                """
                splith focus=1,0
                  w1 0.5000
                  tabbed(splith) 0.5000 focus=1,0
                    w2 0.5000
                    w3 0.5000
                """
            }
            assertInlineSnapshot(of: flush(space), as: .descriptionLines) {
                """
                w1: 20,20 695x860
                w2: 725,44 695x836
                w3: 725,44 695x836
                """
            }
        }

        @Test(arguments: [false, true])
        func autoPadding(enabled: Bool)
        {
            let space = paddedWorkspace(padding: 20, gap: 10)
            space.view.autoPadding = enabled
            space.open(1, focus: true)
            let single = flush(space)
            space.open(2, focus: true)
            let pair = flush(space)
            space.close(2)
            let back = flush(space)

            if enabled {
                // one window fills the display, two keep the padding
                #expect(single.map(\.description) == ["w1: 0,0 1440x900"])
                #expect(pair.map(\.description) == ["w1: 20,20 695x860", "w2: 725,20 695x860"])
                #expect(back.map(\.description) == ["w1: 0,0 1440x900"])
            } else {
                #expect(single.map(\.description) == ["w1: 20,20 1400x860"])
                #expect(pair.map(\.description) == ["w1: 20,20 695x860", "w2: 725,20 695x860"])
                #expect(back.map(\.description) == ["w1: 20,20 1400x860"])
            }
            #expect(space.view.isUnpadded == enabled)
        }
    }
}
