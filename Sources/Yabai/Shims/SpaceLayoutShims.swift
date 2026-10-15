import YabaiCore

//
// NOTE: The SpaceLayout parser (Sources/YabaiCore) for `struct space_layout`, the fixed-size layouts of the space manager.
//

extension SpaceLayout
{
    init(_ layout: space_layout)
    {
        let target = withUnsafeBytes(of: layout.target) { Array($0.bindMemory(to: Int32.self).prefix(Int(layout.count))) }
        self.init(target: target.map(Int.init), builtinIndex: layout.builtin_index == -1 ? nil : Int(layout.builtin_index))
    }
}

/// `space_layout_parse`
func space_layout_parse(_ text: UnsafeMutablePointer<CChar>, _ length: Int32, _ layout: UnsafeMutablePointer<space_layout>) -> Bool
{
    guard let parsed = SpaceLayout(parsing: UnsafeRawBufferPointer(start: text, count: Int(length))) else {
        layout.pointee.count = 0
        layout.pointee.builtin_index = -1
        return false
    }

    layout.pointee.count = Int32(parsed.count)
    layout.pointee.builtin_index = parsed.builtinIndex.map(Int32.init) ?? -1
    withUnsafeMutableBytes(of: &layout.pointee.target) { bytes in
        let target = bytes.bindMemory(to: Int32.self)
        for (i, value) in parsed.target.enumerated() { target[i] = Int32(value) }
    }

    return true
}
