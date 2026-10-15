import CoreText
import Foundation
import Testing
import YabaiC
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
            let wm = window_manager_global()!
            #expect(set("system:13"))
            #expect(String(cString: wm.pointee.tab_bar_font_name) == "system:13")
            #expect(CTFontGetSize(wm.pointee.tab_bar_font!.takeUnretainedValue()) == 13)
            #expect(set("Menlo:11"))
            #expect(CTFontGetSize(wm.pointee.tab_bar_font!.takeUnretainedValue()) == 11)
            #expect(!set("system"))
            #expect(!set("system:0"))
            #expect(!set(":12"))
            #expect(String(cString: wm.pointee.tab_bar_font_name) == "Menlo:11")
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
    }
}
