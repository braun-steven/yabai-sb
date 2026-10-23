import CoreGraphics
import Testing

@testable import YabaiCore

//
// NOTE: The rects of the drop preview (P13.3): the part of a window that a drop covers, and the rect that a dragged
// window's image takes inside it. The rows use a target of 200 by 100 points at the origin unless they say otherwise.
//

@Suite("DropPreview")
struct DropPreviewTests {
  struct CoverRow: Sendable, CustomTestStringConvertible {
    let area: CGRect
    let direction: InsertDirection?
    let expected: CGRect
    var testDescription: String { "\(String(describing: direction)) of \(area)" }
  }

  static let coverRows: [CoverRow] = [
    // the four halves of a target at the origin, with y growing upward as in the outline clip
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: .north,
      expected: CGRect(x: 0, y: 50, width: 200, height: 50)),
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: .south,
      expected: CGRect(x: 0, y: 0, width: 200, height: 50)),
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: .east,
      expected: CGRect(x: 100, y: 0, width: 100, height: 100)),
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: .west,
      expected: CGRect(x: 0, y: 0, width: 100, height: 100)),
    // a stack and a swap cover the whole target
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: .stack,
      expected: CGRect(x: 0, y: 0, width: 200, height: 100)),
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 200, height: 100), direction: nil,
      expected: CGRect(x: 0, y: 0, width: 200, height: 100)),
    // the halves keep the origin of the target
    CoverRow(
      area: CGRect(x: 10, y: 20, width: 200, height: 100), direction: .north,
      expected: CGRect(x: 10, y: 70, width: 200, height: 50)),
    CoverRow(
      area: CGRect(x: 10, y: 20, width: 200, height: 100), direction: .west,
      expected: CGRect(x: 10, y: 20, width: 100, height: 100)),
    // a tall target: the halves split the height
    CoverRow(
      area: CGRect(x: 0, y: 0, width: 100, height: 300), direction: .south,
      expected: CGRect(x: 0, y: 0, width: 100, height: 150)),
  ]

  @Test(arguments: coverRows)
  func coveredPartOfTheTarget(_ row: CoverRow) {
    #expect(DropPreview.covered(row.area, by: row.direction) == row.expected)
  }

  struct FitRow: Sendable, CustomTestStringConvertible {
    let size: CGSize
    let rect: CGRect
    let expected: CGRect?
    var testDescription: String { "\(size) in \(rect)" }
  }

  static let fitRows: [FitRow] = [
    // a square image fills the height of a wide rect and is centered horizontally
    FitRow(
      size: CGSize(width: 100, height: 100), rect: CGRect(x: 0, y: 0, width: 200, height: 100),
      expected: CGRect(x: 50, y: 0, width: 100, height: 100)),
    // a wide image fills the width and is centered vertically
    FitRow(
      size: CGSize(width: 400, height: 100), rect: CGRect(x: 0, y: 0, width: 200, height: 200),
      expected: CGRect(x: 0, y: 75, width: 200, height: 50)),
    // a tall image fills the height and is centered horizontally
    FitRow(
      size: CGSize(width: 50, height: 400), rect: CGRect(x: 0, y: 0, width: 200, height: 100),
      expected: CGRect(x: 93.75, y: 0, width: 12.5, height: 100)),
    // an image of the same aspect as the rect fills it
    FitRow(
      size: CGSize(width: 2, height: 1), rect: CGRect(x: 10, y: 20, width: 200, height: 100),
      expected: CGRect(x: 10, y: 20, width: 200, height: 100)),
    // a small image is scaled up, and the rect's origin is kept
    FitRow(
      size: CGSize(width: 10, height: 10), rect: CGRect(x: 10, y: 20, width: 200, height: 100),
      expected: CGRect(x: 60, y: 20, width: 100, height: 100)),
    // a zero size has nothing to draw
    FitRow(
      size: CGSize(width: 0, height: 100), rect: CGRect(x: 0, y: 0, width: 200, height: 100),
      expected: nil),
    FitRow(
      size: CGSize(width: 100, height: 0), rect: CGRect(x: 0, y: 0, width: 200, height: 100),
      expected: nil),
    // a rect without width or height has nothing to fill
    FitRow(
      size: CGSize(width: 100, height: 100), rect: CGRect(x: 0, y: 0, width: 0, height: 100),
      expected: nil),
    FitRow(
      size: CGSize(width: 100, height: 100), rect: CGRect(x: 0, y: 0, width: 200, height: 0),
      expected: nil),
    // a negative or infinite size is refused
    FitRow(
      size: CGSize(width: -100, height: 100), rect: CGRect(x: 0, y: 0, width: 200, height: 100),
      expected: nil),
    FitRow(
      size: CGSize(width: CGFloat.infinity, height: 100),
      rect: CGRect(x: 0, y: 0, width: 200, height: 100), expected: nil),
  ]

  @Test(arguments: fitRows)
  func imageFitsTheRect(_ row: FitRow) {
    #expect(DropPreview.fit(row.size, in: row.rect) == row.expected)
  }
}
