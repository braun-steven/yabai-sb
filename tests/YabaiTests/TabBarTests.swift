import AppKit
import CPrivate
import CoreText
import Foundation
import OrderedCollections
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

extension DaemonState {
  @Suite
  @WM struct TabBarTests {
    @Test("Tab bar backdrops and appearances are named by their config values")
    func configNames() {
      #expect(TabBarBackdrop.allCases.map(\.rawValue) == ["off", "glass", "blur"])
      #expect(TabBarAppearance.allCases.map(\.rawValue) == ["dark", "system"])
      #expect(TabBarBackdrop(rawValue: "solid") == nil)
    }

    @Test("tab_bar_font_parse")
    func fontParse() {
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

    @Test("tab_bar_slots_cover_bar")
    func slotsCoverBar() {
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
    func glassHitSlots() {
      let frame = Self.hitFrame
      let inner = TabBarRenderer.innerRect(frame)
      let boundary = TabBar.slot(in: inner, index: 0, count: 3).maxX
      #expect(
        TabBar.hitIndex(CGPoint(x: boundary - 0.1, y: 21), frame: frame, slots: inner, count: 3)
          == 0)
      #expect(
        TabBar.hitIndex(CGPoint(x: boundary, y: 21), frame: frame, slots: inner, count: 3) == 1)
      #expect(TabBarRenderer.innerRect(CGRect(x: 0, y: 0, width: 1, height: 1)).width >= 0)
    }

    nonisolated static let hitFrame = CGRect(x: 10, y: 20, width: 103, height: 24)

    nonisolated static let hitRows: [(CGFloat, Int, Int?)] = [
      (10, 3, 0),
      (112.9, 3, 2),
      (9, 3, nil),
      (12, 0, nil),
      (45, 3, 1),
    ]

    @Test(arguments: hitRows)
    func hitIndex(_ x: CGFloat, _ count: Int, _ index: Int?) {
      #expect(
        TabBar.hitIndex(
          CGPoint(x: x, y: 21), frame: Self.hitFrame,
          slots: TabBarRenderer.innerRect(Self.hitFrame),
          count: count) == index)
    }

    // NOTE: The key is built from values only, so a bar is never drawn in these tests: the draw count is the number of
    // draws the gate allows for the keys of a sequence of renders.
    static func renderKey(
      title: String? = "Safari", state: TabBarState = .focused, generation: Int = 0
    ) -> TabBarRenderKey {
      TabBarRenderKey(
        frame: CGRect(x: 10, y: 20, width: 300, height: 24), card: .zero,
        aboveWid: WindowID(rawValue: 0xFFFF_0001), sid: SpaceID(rawValue: 0xFFFF_0100),
        level: 0, subLevel: 0, generation: generation, mainDisplayHeight: 900,
        entries: [
          TabBarRenderKey.Entry(
            focusWindowID: WindowID(rawValue: 0xFFFF_0001), title: title, icon: nil, state: state)
        ])
    }

    @Test(
      "tab bar renders with an equal key draw once; a config change, a title or a state draws again"
    )
    func renderDrawsOnlyWhenTheKeyChanges() {
      var gate = RenderGate<TabBarRenderKey>()
      let keys = [
        Self.renderKey(), Self.renderKey(), Self.renderKey(generation: 1),
        Self.renderKey(generation: 1), Self.renderKey(title: "Notes", generation: 1),
        Self.renderKey(title: "Notes", state: .unfocused, generation: 1),
      ]
      let draws = keys.filter { gate.needsDraw($0) }
      #expect(draws.count == 4)
    }

    @Test("tab_bar_backdrop_change_destroys_the_backend")
    func backdropChangeDestroysTheBackend() {
      let space = Workspace()
      space.open(1, focus: true)
      space.open(2, focus: true)
      space.view.root.setLayout(.tabbed)
      let bar = space.view.root.render.tabBar
      bar.backend = TabBarRenderer()
      WindowManager.shared.tabBars.append(bar)

      // the config command applies the new backdrop this way
      let old = Config.current.tabBar
      Config.current.tabBar.backdrop = .off
      TabBar.applyConfig(Config.current.tabBar, from: old)

      #expect(bar.backend == nil)
      #expect(!WindowManager.shared.tabBars.contains(bar))
    }

    @Test("tab_bar_nested_card_order")
    func nestedCardOrder() {
      let outer = TabBar()
      outer.card = CGRect(x: 0, y: 0, width: 1000, height: 800)
      let inner = TabBar()
      inner.card = CGRect(x: 6, y: 32, width: 988, height: 762)
      let deepest = TabBar()
      deepest.card = CGRect(x: 12, y: 64, width: 976, height: 724)
      #expect(TabBar.outerFirst([inner, deepest, outer]) == [outer, inner, deepest])
      #expect(TabBar.outerFirst([outer, inner, deepest]) == [outer, inner, deepest])
    }

    nonisolated static let cardPaddingRows: [(TabBarBackdrop, Int)] = [
      (.glass, 6),
      (.blur, 6),
      (.off, 0),
    ]

    @Test(arguments: cardPaddingRows)
    func cardPaddingOnlyWithABackdrop(_ backdrop: TabBarBackdrop, _ padding: Int) {
      Config.current.tabBar.backdrop = backdrop
      Config.current.tabBar.cardPadding = 6
      #expect(TabBar.cardPadding == padding)
    }

    @Test(arguments: [true, false], [Float(0), 0.4, 1])
    func glassTint(_ custom: Bool, _ alpha: Float) {
      let color = RGBAColor(hex: 0x80_28_55_77)
      let tint = TabBarRenderer.tint(color, custom: custom, alpha: alpha)
      #expect(
        [tint.r, tint.g, tint.b, tint.argb] == [color.r, color.g, color.b, color.argb]
          as [AnyHashable])
      #expect(tint.a == (custom ? color.a : alpha))
    }
  }
}
