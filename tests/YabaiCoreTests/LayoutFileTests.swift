import Foundation
import Testing
import YabaiTestSupport

@testable import YabaiCore

@Suite("layout file")
struct LayoutFileTests {
  private let file = LayoutFile(snapshot: LayoutFixtures.tree, matcher: LayoutFixtures.matcher)

  @Test("a tree keeps its shape, its focus order and a matcher per leaf, and no selection")
  func fileFromSnapshot() {
    #expect(file.version == 1)
    #expect(file.tree.layout == .splitH)
    #expect(file.tree.children.count == 2)
    #expect(file.tree.children[0].window == LayoutFixtures.matchers[1])
    #expect(file.tree.children[0].children.isEmpty)
    #expect(file.tree.focusOrder == [1, 0])

    let tabbed = file.tree.children[1]
    #expect(tabbed.layout == .tabbed)
    #expect(tabbed.lastSplit == .splitV)
    #expect(tabbed.zoom == .parent)
    #expect(tabbed.window == nil)
    #expect(tabbed.children[0].children[1].window == nil)
    #expect(tabbed.children[1].window == LayoutFixtures.matchers[4])
  }

  @Test("encoding then decoding gives the same file")
  func roundTrip() throws {
    let data = try LayoutFile.encode(file)
    #expect(try LayoutFile.decode(data) == file)
  }

  @Test("the encoded file ends with a newline, keeps slashes and leaves out the selection")
  func encodedShape() throws {
    let text = String(decoding: try LayoutFile.encode(file), as: UTF8.self)
    #expect(text.hasSuffix("}\n"))
    #expect(text.contains("Work/Inbox"))
    #expect(!text.contains("isSelected"))
    #expect(!text.contains("\\/"))
  }

  @Test("the same tree always encodes to the same bytes")
  func encodingIsStable() throws {
    let again = LayoutFile(snapshot: LayoutFixtures.tree, matcher: LayoutFixtures.matcher)
    #expect(try LayoutFile.encode(file) == LayoutFile.encode(again))
  }

  @Test(arguments: ["work", "a.b-c_1", "A", "0", "-", "..x", "x.."])
  func validNames(_ name: String) {
    #expect(LayoutStore.isValidName(name))
  }

  @Test(arguments: ["", "a/b", "/", "..", ".", "a b", "ü", "a\\b", "a\nb", "a:b", "a*"])
  func invalidNames(_ name: String) {
    #expect(!LayoutStore.isValidName(name))
  }

  @Test(
    arguments: [
      ("/xdg", "/home/u", "/xdg/yabai/layouts"),
      ("", "/home/u", "/home/u/.config/yabai/layouts"),
      (nil, "/home/u", "/home/u/.config/yabai/layouts"),
      ("/xdg", nil, "/xdg/yabai/layouts"),
      (nil, "", nil),
      (nil, nil, nil),
    ] as [(String?, String?, String?)])
  func layoutDirectory(_ xdg: String?, _ home: String?, _ expected: String?) {
    #expect(LayoutStore.directory(xdgConfigHome: xdg, home: home) == expected)
  }

  @Test func layoutPathIsNameDotJson() {
    #expect(LayoutStore.path(name: "work", directory: "/d") == "/d/work.json")
  }
}
