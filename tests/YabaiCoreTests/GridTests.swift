import CoreGraphics
import PropertyBased
import Testing
@testable import YabaiCore
import YabaiTestSupport

//
// NOTE: `Grid.frame(in:padding:gap:)`, the frame of `window --grid` and of the grid= rule effect.
//

private typealias Padding = (top: Int, bottom: Int, left: Int, right: Int)

private let display = CGRect(x: 0, y: 0, width: 1000, height: 500)

@Suite struct GridTests
{
    static let frames: [(Grid, CGRect, Area)] = [
        (Grid(1, 1, 0, 0, 1, 1), CGRect(x: 0, y: 0, width: 1440, height: 900), Area(x: 0, y: 0, w: 1440, h: 900)),
        (Grid(2, 2, 1, 1, 1, 1), CGRect(x: 100, y: 50, width: 1000, height: 600), Area(x: 600, y: 350, w: 500, h: 300)),
        (Grid(2, 2, 0, 0, 2, 1), CGRect(x: 100, y: 50, width: 1000, height: 600), Area(x: 100, y: 50, w: 1000, h: 300)),
        (Grid(4, 4, 1, 2, 2, 2), display, Area(x: 250, y: 250, w: 500, h: 250)),
        // a display left of or above the main one
        (Grid(1, 2, 1, 0, 1, 1), CGRect(x: -1728, y: -200, width: 1728, height: 1117), Area(x: -864, y: -200, w: 864, h: 1117)),
        // x and y are limited to the last column and row, width and height to at least one cell and the rest of the grid
        (Grid(2, 2, 5, 5, 0, 0), display, Area(x: 500, y: 250, w: 500, h: 250)),
        (Grid(2, 2, 0, 0, 9, 9), display, Area(x: 0, y: 0, w: 1000, h: 500)),
        (Grid(2, 2, 1, 0, 9, 1), display, Area(x: 500, y: 0, w: 500, h: 250)),
        // negative values arrive as their bit patterns
        (Grid(2, 2, .max, .max, .max, .max), display, Area(x: 500, y: 250, w: 500, h: 250)),
    ]

    @Test(arguments: frames)
    func frameOfACell(_ grid: Grid, _ bounds: CGRect, _ expected: Area)
    {
        #expect(grid.frame(in: bounds, padding: nil, gap: nil) == expected)
    }

    @Test func paddingInsetsTheGrid()
    {
        let padding: Padding = (top: 10, bottom: 20, left: 30, right: 40)
        #expect(Grid(1, 2, 0, 0, 1, 1).frame(in: display, padding: padding, gap: nil) == Area(x: 30, y: 10, w: 465, h: 470))
        #expect(Grid(1, 2, 1, 0, 1, 1).frame(in: display, padding: padding, gap: nil) == Area(x: 495, y: 10, w: 465, h: 470))
        #expect(Grid(1, 1, 0, 0, 1, 1).frame(in: display, padding: (top: 0, bottom: 0, left: 0, right: 0), gap: nil) == Area(x: 0, y: 0, w: 1000, h: 500))
    }

    @Test func gapSeparatesNeighboringCells()
    {
        // two halves: each gives up the gap on the side of the other one
        #expect(Grid(1, 2, 0, 0, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 0, y: 0, w: 490, h: 500))
        #expect(Grid(1, 2, 1, 0, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 510, y: 0, w: 490, h: 500))
        #expect(Grid(2, 1, 0, 1, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 0, y: 260, w: 1000, h: 240))
        // a cell that fills the grid has no neighbor
        #expect(Grid(2, 2, 0, 0, 2, 2).frame(in: display, padding: nil, gap: 20) == Area(x: 0, y: 0, w: 1000, h: 500))
        #expect(Grid(1, 1, 0, 0, 1, 1).frame(in: display, padding: (top: 5, bottom: 5, left: 5, right: 5), gap: 20) == Area(x: 5, y: 5, w: 990, h: 490))
    }

    // NOTE: The cells of a grid are the same size and one gap apart, also with three or more columns.
    @Test(arguments: [nil, 0, 20, 7])
    func cellsAreEqualAndOneGapApart(_ gap: Int?)
    {
        let padding: Padding = (top: 10, bottom: 20, left: 30, right: 40)
        for columns in UInt32(1)...6 {
            let cells = (0..<columns).map { Grid(2, columns, $0, 1, 1, 1).frame(in: display, padding: padding, gap: gap) }
            let width = cells[0].w
            for (index, cell) in cells.enumerated() {
                #expect(abs(cell.w - width) < 1e-3, "\(columns) columns, cell \(index)")
                #expect(cell.y == cells[0].y && cell.h == cells[0].h)
            }
            for (left, right) in zip(cells, cells.dropFirst()) {
                #expect(abs(right.x - (left.x + left.w) - Float(gap ?? 0)) < 1e-3, "\(columns) columns")
            }
            #expect(cells[0].x == 30)
            #expect(abs(cells.last!.x + cells.last!.w - 960) < 1e-3)
        }
    }

    @Test func cellsOfThreeColumns()
    {
        #expect(Grid(1, 3, 0, 0, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 0, y: 0, w: 320, h: 500))
        #expect(Grid(1, 3, 1, 0, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 340, y: 0, w: 320, h: 500))
        #expect(Grid(1, 3, 2, 0, 1, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 680, y: 0, w: 320, h: 500))
        // a cell of two columns covers the gap between them
        #expect(Grid(1, 3, 1, 0, 2, 1).frame(in: display, padding: nil, gap: 20) == Area(x: 340, y: 0, w: 660, h: 500))
    }

    @Test func gridWithoutRowsOrColumnsIsNotFinite()
    {
        let frame = Grid(0, 0, 0, 0, 0, 0).frame(in: display, padding: nil, gap: nil)
        #expect(!frame.x.isFinite && !frame.w.isFinite)
        #expect(!frame.y.isFinite && !frame.h.isFinite)
    }

    // NOTE: Without a gap, a cell of a grid is the union of the one-cell placements it covers.
    @Test func cellsTileTheBounds() async
    {
        await propertyCheck(count: 300, input: Gen.int(in: 1...12), Gen.int(in: 1...12), Gen.int(in: 0...11), Gen.int(in: 0...11), Gen.int(in: 1...12), Gen.int(in: 1...12)) { rows, columns, x, y, width, height in
            let bounds = CGRect(x: -300, y: 25, width: 1920, height: 1080)
            let grid = Grid(UInt32(rows), UInt32(columns), UInt32(x), UInt32(y), UInt32(width), UInt32(height))
            let frame = grid.frame(in: bounds, padding: nil, gap: nil)

            let cx = min(x, columns - 1), cy = min(y, rows - 1)
            let first = Grid(UInt32(rows), UInt32(columns), UInt32(cx), UInt32(cy), 1, 1).frame(in: bounds, padding: nil, gap: nil)
            let cw = min(width, columns - cx), ch = min(height, rows - cy)
            let last = Grid(UInt32(rows), UInt32(columns), UInt32(cx + cw - 1), UInt32(cy + ch - 1), 1, 1).frame(in: bounds, padding: nil, gap: nil)

            #expect(abs(frame.x - first.x) < 1e-2 && abs(frame.y - first.y) < 1e-2)
            #expect(abs((frame.x + frame.w) - (last.x + last.w)) < 1e-2)
            #expect(abs((frame.y + frame.h) - (last.y + last.h)) < 1e-2)
            #expect(frame.x >= -300 - 1e-2 && frame.x + frame.w <= 1620 + 1e-2)
            #expect(frame.y >= 25 - 1e-2 && frame.y + frame.h <= 1105 + 1e-2)
        }
    }
}
