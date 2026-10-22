import AppKit
import CoreText
import Foundation
import SnapshotTesting
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
            let frame = Self.hitFrame
            let inner = TabBarGlass.innerRect(frame)
            let boundary = TabBar.slot(in: inner, index: 0, count: 3).maxX
            #expect(TabBar.hitIndex(CGPoint(x: boundary - 0.1, y: 21), frame: frame, slots: inner, count: 3) == 0)
            #expect(TabBar.hitIndex(CGPoint(x: boundary, y: 21), frame: frame, slots: inner, count: 3) == 1)
            #expect(TabBarGlass.innerRect(CGRect(x: 0, y: 0, width: 1, height: 1)).width >= 0)
        }

        nonisolated static let hitFrame = CGRect(x: 10, y: 20, width: 103, height: 24)

        nonisolated static let hitRows: [(CGFloat, Int, Bool, Int?)] = [
            (10, 3, true, 0),
            (112.9, 3, true, 2),
            (9, 3, true, nil),
            (12, 0, true, nil),
            (44, 3, false, 1),
        ]

        @Test(arguments: hitRows)
        func hitIndex(_ x: CGFloat, _ count: Int, _ glass: Bool, _ index: Int?)
        {
            let slots = glass ? TabBarGlass.innerRect(Self.hitFrame) : Self.hitFrame
            #expect(TabBar.hitIndex(CGPoint(x: x, y: 21), frame: Self.hitFrame, slots: slots, count: count) == index)
        }

        nonisolated static let backendKindRows: [(TabBarStyle, TabBarBackend.Kind)] = [
            (.glass, .glass),
            (.i3, .classic),
        ]

        // NOTE: Only the choice is tested: make would create a classic window in the window server.
        @Test(arguments: backendKindRows)
        func backendFollowsTheStyle(_ style: TabBarStyle, _ kind: TabBarBackend.Kind)
        {
            #expect(TabBarBackend.kind(for: style) == kind)
        }

        @Test("tab_bar_style_switch_destroys_the_backend")
        func styleSwitchDestroysTheBackend()
        {
            Config.current.tabBar.style = .glass
            let space = Workspace()
            space.open(1, focus: true)
            space.open(2, focus: true)
            space.view.root.setLayout(.tabbed)
            let bar = space.view.root.render.tabBar
            bar.backend = .glass(TabBarGlass())
            WindowManager.shared.tabBars.append(bar)

            // the config command applies the new style this way
            let old = Config.current.tabBar
            Config.current.tabBar.style = .i3
            TabBar.applyConfig(Config.current.tabBar, from: old)

            #expect(bar.backend == nil)
            #expect(!WindowManager.shared.tabBars.contains(bar))
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

        /// A 16 pixel icon: a blue square with a white diagonal, so that its placement and scale show.
        private static func icon() -> CGImage
        {
            let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.setLineWidth(2)
            context.strokeLineSegments(between: [CGPoint(x: 0, y: 0), CGPoint(x: 16, y: 16)])
            return context.makeImage()!
        }

        //
        // NOTE: The text rendering depends on the OS build; disable this test (not the others) when an update changes
        // it, then record it again.
        //
        @Test func titlesDrawnIntoTabs()
        {
            let width = 320, height = 30 * 5
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: 0.16, green: 0.33, blue: 0.47, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            let icon = Self.icon()

            // from the top: i3 with an icon, glass with an icon, a truncated title, only an icon, only a title
            let rows: [(glass: Bool, title: String?, icon: CGImage?, width: CGFloat)] = [
                (false, "Terminal", icon, 320),
                (true, "Terminal", icon, 320),
                (false, "A title much longer than its tab", icon, 160),
                (true, nil, icon, 320),
                (false, "Untitled", nil, 320),
            ]
            for (index, row) in rows.enumerated() {
                let rect = CGRect(x: 0, y: CGFloat(height - 30 * (index + 1)), width: row.width, height: 30)
                TabBar.drawTitle(in: context, font: font, glass: row.glass, title: row.title.map { $0 as CFString }, icon: row.icon, rect: rect, color: white)
            }

            let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
            assertSnapshot(of: image, as: .image(perceptualPrecision: 0.98))
        }

        @Test func nothingIsDrawnIntoATabWithoutRoom()
        {
            let context = CGContext(data: nil, width: 16, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            TabBar.drawTitle(in: context, font: font, glass: false, title: "Terminal" as CFString, icon: Self.icon(),
                             rect: CGRect(x: 0, y: 0, width: 16, height: 30), color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            #expect((0..<(context.bytesPerRow * 30)).allSatisfy { pixels[$0] == 0 })
        }
    }
}
