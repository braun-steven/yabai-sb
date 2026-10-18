import CoreText
import Foundation
import Testing
import CPrivate
@testable import Yabai

extension DaemonState
{
    @Suite
    struct TabBarTests
    {
        @Test("tab_bar_style_parse")
        func styleParse()
        {
            var style = TAB_BAR_STYLE_COUNT
            func parse(_ name: String) -> Bool {
                let text = strdup(name)!
                defer { free(text) }
                return Yabai.tab_bar_parse_style(text, &style)
            }
            #expect(parse("glass"))
            #expect(style == TAB_BAR_STYLE_GLASS)
            #expect(!parse("classic"))
            #expect(parse("i3"))
            #expect(style == TAB_BAR_STYLE_I3)
            #expect(!parse("auto"))
            #expect(!parse(""))
            #expect(style == TAB_BAR_STYLE_I3)
        }

        @Test("tab_bar_backdrop_parse")
        func backdropParse()
        {
            var backdrop = TAB_BAR_BACKDROP_COUNT
            for (name, expected) in [("glass", TAB_BAR_BACKDROP_GLASS), ("blur", TAB_BAR_BACKDROP_BLUR), ("off", TAB_BAR_BACKDROP_OFF)] {
                let text = strdup(name)!
                defer { free(text) }
                #expect(Yabai.tab_bar_parse_backdrop(text, &backdrop))
                #expect(backdrop == expected)
            }
            let text = strdup("solid")!
            defer { free(text) }
            #expect(!Yabai.tab_bar_parse_backdrop(text, &backdrop))
            #expect(backdrop == TAB_BAR_BACKDROP_OFF)
        }

        @Test("tab_bar_font_parse")
        func fontParse()
        {
            func set(_ name: String) -> Bool {
                let text = strdup(name)!
                defer { free(text) }
                return Yabai.tab_bar_set_font(text)
            }
            let wm = window_manager_global()
            #expect(set("system:13"))
            #expect(String(cString: wm.tab_bar_font_name) == "system:13")
            #expect(CTFontGetSize(wm.tab_bar_font!) == 13)
            #expect(set("Menlo:11"))
            #expect(CTFontGetSize(wm.tab_bar_font!) == 11)
            #expect(!set("system"))
            #expect(!set("system:0"))
            #expect(!set(":12"))
            #expect(String(cString: wm.tab_bar_font_name) == "Menlo:11")
        }

        @Test("tab_bar_glass_tint_default")
        func glassTintDefault()
        {
            let color = rgba_color_from_hex(0xff285577)
            let tint = Yabai.tab_bar_glass_tint(color, false, 0.4)
            #expect(Int(tint.a * 100 + 0.5) == 40)
            #expect(tint.r == color.r && tint.g == color.g && tint.b == color.b)
            let custom = Yabai.tab_bar_glass_tint(color, true, 0.4)
            #expect(custom.a == color.a)
            #expect(custom.p == color.p)
        }

        @Test("tab_bar_title_fits")
        func titleFits()
        {
            let font = CTFontCreateUIFontForLanguage(.system, 13, nil)!
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            func width(_ limit: Double) -> Double {
                let line = tabBarCreateFittedLine("Untitled Document" as CFString, attributes, limit)
                return CTLineGetTypographicBounds(line, nil, nil, nil)
            }
            let full = width(1000)
            #expect(full > 50)
            #expect(width(50) <= 50)
            #expect(width(full) == full)
        }

        @Test("tab_bar_slots_cover_bar")
        func slotsCoverBar()
        {
            let bounds = CGRect(x: 10, y: 0, width: 100, height: 20)
            let first = tab_bar_slot(bounds, 0, 3)
            let second = tab_bar_slot(bounds, 1, 3)
            let last = tab_bar_slot(bounds, 2, 3)
            // NOTE: slots are whole pixels without gaps, and the last one takes the rest
            #expect(first.minX == 10)
            #expect(first.width == 33)
            #expect(second.minX == 43)
            #expect(second.maxX == last.minX)
            #expect(last.maxX == 110)
            #expect(tab_bar_slot(bounds, 0, 1).width == 100)
        }

        @Test("tab_bar_glass_hit_slots")
        func glassHitSlots()
        {
            let frame = CGRect(x: 10, y: 20, width: 103, height: 24)
            let inner = tabBarGlassInnerRect(frame)
            let boundary = tab_bar_slot(inner, 0, 3).maxX
            #expect(tabBarHitIndex(CGPoint(x: boundary - 0.1, y: 21), frame: frame, count: 3, glass: true) == 0)
            #expect(tabBarHitIndex(CGPoint(x: boundary, y: 21), frame: frame, count: 3, glass: true) == 1)
            #expect(tabBarHitIndex(CGPoint(x: 10, y: 21), frame: frame, count: 3, glass: true) == 0)
            #expect(tabBarHitIndex(CGPoint(x: 112.9, y: 21), frame: frame, count: 3, glass: true) == 2)
            #expect(tabBarHitIndex(CGPoint(x: 9, y: 21), frame: frame, count: 3, glass: true) == nil)
            #expect(tabBarHitIndex(CGPoint(x: 12, y: 21), frame: frame, count: 0, glass: true) == nil)
            #expect(tabBarGlassInnerRect(CGRect(x: 0, y: 0, width: 1, height: 1)).width >= 0)
            #expect(tabBarHitIndex(CGPoint(x: 44, y: 21), frame: frame, count: 3, glass: false) == 1)
        }

        @Test("tab_bar_nested_card_order")
        func nestedCardOrder()
        {
            let outer = TabBar()
            outer.card = CGRect(x: 0, y: 0, width: 1000, height: 800)
            let inner = TabBar()
            inner.card = CGRect(x: 6, y: 32, width: 988, height: 762)
            let deepest = TabBar()
            deepest.card = CGRect(x: 12, y: 64, width: 976, height: 724)
            #expect(tabBarOuterFirst([inner, deepest, outer]) == [outer, inner, deepest])
            #expect(tabBarOuterFirst([outer, inner, deepest]) == [outer, inner, deepest])
        }

        @Test("tab_bar_backdrop_below_all_active_split_windows")
        func backdropBelowActiveSplit()
        {
            // T[1 H[2 H[3 4] T[5 6]]]: snapshot only the visible descendants.
            let root = Yabai.con_create(CON_TABBED)!
            defer { Yabai.con_free(root) }
            let single = treeTestLeaf(root, 1)
            let split = treeTestSplit(root, CON_SPLITH)
            let first = treeTestLeaf(split, 2)
            let nested = treeTestSplit(split, CON_SPLITH)
            let second = treeTestLeaf(nested, 3)
            treeTestLeaf(nested, 4)
            let tabs = treeTestSplit(split, CON_TABBED)
            treeTestLeaf(tabs, 5)
            let last = treeTestLeaf(tabs, 6)
            Yabai.tree_focus(last)
            Yabai.tree_focus(second)
            var content: [UInt32] = []
            treeCollectBarContent(root.focus[0], &content)
            #expect(content == [2, 3, 4, 6])
            // Include a nested card (99); hidden windows and unrelated windows are never anchors.
            content.append(99)
            #expect(tabBarBackdropAnchor(content, [3, 2, 4, 6, 99, 1, 5, 88], 3) == 99)
            #expect(tabBarBackdropAnchor(content, [2, 3, 6, 99, 4, 1, 5], 2) == 4)
            #expect(tabBarBackdropAnchor(content, [], 3) == 3)
            #expect(!tabBarPanelNeedsOrder(99, 3, true, [3, 88, 99, 1]))
            #expect(tabBarPanelNeedsOrder(99, 3, true, [99, 3, 1]))
            #expect(!tabBarPanelNeedsOrder(99, 3, false, [99, 3, 1]))
            #expect(tabBarPanelNeedsOrder(99, 3, false, [3, 99, 1]))
            // A late application raise must be repaired; notifications from a correct SA order
            // must settle without ordering the same windows again.
            let orders = [sa_window_order(a_wid: 3, order: 1, b_wid: 99),
                          sa_window_order(a_wid: 1, order: -1, b_wid: 99)]
            #expect(!treeWindowOrderNeedsUpdate(orders, [3, 99, 1]))
            #expect(treeWindowOrderNeedsUpdate(orders, [3, 1, 99]))
            #expect(treeWindowOrderNeedsUpdate(orders, [99, 3, 1]))
            #expect(!treeWindowOrderNeedsUpdate(orders, []))
            var visibleOrder: [sa_window_order] = []
            treeCollectWindowOrder(split, 1, 99, &visibleOrder, excluding: 3)
            #expect(visibleOrder.map(\.a_wid) == [2, 4, 6])
            #expect(visibleOrder.allSatisfy { $0.b_wid == 99 })
            // Nested tab ordering may swap visible siblings without violating the outer card.
            #expect(!treeWindowOrderNeedsUpdate(visibleOrder, [6, 4, 2, 99]))
            #expect(!treeWindowOrderNeedsUpdate(visibleOrder, [2, 4, 6, 99]))
            Yabai.tree_focus(first)
            var switched: [UInt32] = []
            treeCollectBarContent(root.focus[0], &switched)
            #expect(switched == [2, 3, 4, 6])
            Yabai.tree_focus(single)
            switched = []
            treeCollectBarContent(root.focus[0], &switched)
            #expect(switched == [1])
        }
    }
}
