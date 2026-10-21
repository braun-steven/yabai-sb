import CoreText
import Foundation
import Testing
import CPrivate
@testable import Yabai
import YabaiTestSupport

extension DaemonState
{
    @Suite
    @WM struct TabBarTests
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
                return TabBar.setFont(name)
            }
            #expect(set("system:13"))
            #expect(Config.current.tabBar.fontName == "system:13")
            let wm = WindowManager.shared
            #expect(CTFontGetSize(wm.tabBarFont!) == 13)
            #expect(set("Menlo:11"))
            #expect(CTFontGetSize(wm.tabBarFont!) == 11)
            #expect(!set("system"))
            #expect(!set("system:0"))
            #expect(!set(":12"))
            #expect(Config.current.tabBar.fontName == "Menlo:11")
        }

        @Test("tab_bar_title_fits")
        func titleFits()
        {
            let font = CTFontCreateUIFontForLanguage(.system, 13, nil)!
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            func width(_ limit: Double) -> Double {
                let line = TabBar.fittedLine("Untitled Document" as CFString, attributes: attributes, maxWidth: limit)
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
            let first = TabBar.slot(in: bounds, index: 0, count: 3)
            let second = TabBar.slot(in: bounds, index: 1, count: 3)
            let last = TabBar.slot(in: bounds, index: 2, count: 3)
            // NOTE: slots are whole pixels without gaps, and the last one takes the rest
            #expect(first.minX == 10)
            #expect(first.width == 33)
            #expect(second.minX == 43)
            #expect(second.maxX == last.minX)
            #expect(last.maxX == 110)
            #expect(TabBar.slot(in: bounds, index: 0, count: 1).width == 100)
        }

        @Test("tab_bar_glass_hit_slots")
        func glassHitSlots()
        {
            let frame = CGRect(x: 10, y: 20, width: 103, height: 24)
            let inner = TabBarGlass.innerRect(frame)
            let boundary = TabBar.slot(in: inner, index: 0, count: 3).maxX
            #expect(TabBar.hitIndex(CGPoint(x: boundary - 0.1, y: 21), frame: frame, count: 3, glass: true) == 0)
            #expect(TabBar.hitIndex(CGPoint(x: boundary, y: 21), frame: frame, count: 3, glass: true) == 1)
            #expect(TabBar.hitIndex(CGPoint(x: 10, y: 21), frame: frame, count: 3, glass: true) == 0)
            #expect(TabBar.hitIndex(CGPoint(x: 112.9, y: 21), frame: frame, count: 3, glass: true) == 2)
            #expect(TabBar.hitIndex(CGPoint(x: 9, y: 21), frame: frame, count: 3, glass: true) == nil)
            #expect(TabBar.hitIndex(CGPoint(x: 12, y: 21), frame: frame, count: 0, glass: true) == nil)
            #expect(TabBarGlass.innerRect(CGRect(x: 0, y: 0, width: 1, height: 1)).width >= 0)
            #expect(TabBar.hitIndex(CGPoint(x: 44, y: 21), frame: frame, count: 3, glass: false) == 1)
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
            #expect(TabBar.outerFirst([inner, deepest, outer]) == [outer, inner, deepest])
            #expect(TabBar.outerFirst([outer, inner, deepest]) == [outer, inner, deepest])
        }

        @Test(arguments: [UInt32(0xFFFF_FFFF), 0x80FF_8000, 0x0000_0000, 0x0C12_3456])
        func separatorIsTheTextAtAQuarterOfItsAlpha(_ hex: UInt32)
        {
            let text = RGBAColor(hex: hex)
            let separator = TabBar.separatorColor(for: text)
            #expect(separator.a == text.a * 0.25)
            #expect([separator.r, separator.g, separator.b] == [text.r, text.g, text.b])
            #expect(separator.argb == text.argb)
        }

        nonisolated static let cardPaddingRows: [(TabBarStyle, TabBarBackdrop, Int)] = [
            (.glass, .glass, 6),
            (.glass, .blur, 6),
            (.glass, .off, 0),
            (.i3, .glass, 0),
            (.i3, .blur, 0),
            (.i3, .off, 0),
        ]

        @Test(arguments: cardPaddingRows)
        func cardPaddingOnlyWithAGlassBackdrop(_ style: TabBarStyle, _ backdrop: TabBarBackdrop, _ padding: Int)
        {
            Config.current.tabBar.style = style
            Config.current.tabBar.backdrop = backdrop
            Config.current.tabBar.cardPadding = 6
            #expect(TabBar.cardPadding == padding)
        }

        @Test(arguments: [true, false], [Float(0), 0.4, 1])
        func glassTint(_ custom: Bool, _ alpha: Float)
        {
            let color = RGBAColor(hex: 0x80_28_55_77)
            let tint = TabBarGlass.tint(color, custom: custom, alpha: alpha)
            #expect([tint.r, tint.g, tint.b, tint.argb] == [color.r, color.g, color.b, color.argb] as [AnyHashable])
            #expect(tint.a == (custom ? color.a : alpha))
        }
    }
}
