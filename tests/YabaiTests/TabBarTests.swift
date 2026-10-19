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
        @Test("Tab bar styles, backdrops and appearances are named by their config values")
        func configNames()
        {
            #expect(TabBarStyle.allCases.map(\.rawValue) == ["glass", "i3"])
            #expect(TabBarBackdrop.allCases.map(\.rawValue) == ["off", "glass", "blur"])
            #expect(TabBarAppearance.allCases.map(\.rawValue) == ["dark", "system"])
            #expect(TabBarStyle(rawValue: "classic") == nil)
            #expect(TabBarBackdrop(rawValue: "solid") == nil)
        }

        @Test("tab_bar_font_parse")
        func fontParse()
        {
            func set(_ name: String) -> Bool {
                return Yabai.tab_bar_set_font(name)
            }
            let wm = WindowManager.shared
            #expect(set("system:13"))
            #expect(wm.tabBarFontName == "system:13")
            #expect(CTFontGetSize(wm.tabBarFont!) == 13)
            #expect(set("Menlo:11"))
            #expect(CTFontGetSize(wm.tabBarFont!) == 11)
            #expect(!set("system"))
            #expect(!set("system:0"))
            #expect(!set(":12"))
            #expect(wm.tabBarFontName == "Menlo:11")
        }

        @Test("tab_bar_glass_tint_default")
        func glassTintDefault()
        {
            let color = RGBAColor(hex: 0xff285577)
            let tint = Yabai.tab_bar_glass_tint(color, false, 0.4)
            #expect(Int(tint.a * 100 + 0.5) == 40)
            #expect(tint.r == color.r && tint.g == color.g && tint.b == color.b)
            let custom = Yabai.tab_bar_glass_tint(color, true, 0.4)
            #expect(custom.a == color.a)
            #expect(custom.argb == color.argb)
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
    }
}
