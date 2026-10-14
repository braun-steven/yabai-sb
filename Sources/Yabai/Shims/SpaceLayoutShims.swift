import YabaiC
import YabaiCore

//
// NOTE: The C entry points of SpaceLayout and SpaceList (Sources/YabaiCore) while message_config.c, space_layout.c
// and space_manager.c are C. `struct space_layout` stays C until the space manager is Swift (P9).
//

extension SpaceLayout
{
    init(_ layout: space_layout)
    {
        let target = withUnsafeBytes(of: layout.target) { Array($0.bindMemory(to: Int32.self).prefix(Int(layout.count))) }
        self.init(target: target.map(Int.init), builtinIndex: layout.builtin_index == -1 ? nil : Int(layout.builtin_index))
    }
}

@_cdecl("space_layout_parse")
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

@_cdecl("space_layout_targets")
func space_layout_targets(_ layout: UnsafeMutablePointer<space_layout>, _ builtin: Int32, _ target: UnsafeMutablePointer<Int32>)
{
    let targets = SpaceLayout(layout.pointee).targets(builtin: builtin == -1 ? nil : Int(builtin))
    for (i, value) in targets.enumerated() { target[i] = Int32(value) }
}

private func spaceLists(_ spaceList: UnsafeMutablePointer<UInt64>?, _ userList: UnsafeMutablePointer<Bool>?, _ count: Int32) -> ([UInt64], [Bool])
{
    (Array(UnsafeBufferPointer(start: spaceList, count: Int(count))), Array(UnsafeBufferPointer(start: userList, count: Int(count))))
}

@_cdecl("space_layout_move_candidate")
func space_layout_move_candidate(_ spaceList: UnsafeMutablePointer<UInt64>?, _ userList: UnsafeMutablePointer<Bool>?, _ count: Int32, _ visibleSid: UInt64, _ fromEnd: Bool) -> UInt64
{
    let (spaces, user) = spaceLists(spaceList, userList, count)
    return SpaceLayout.moveCandidate(spaces: spaces, user: user, visible: visibleSid, fromEnd: fromEnd)
}

@_cdecl("space_manager_move_space_replacement")
func space_manager_move_space_replacement(_ spaceList: UnsafeMutablePointer<UInt64>?, _ userList: UnsafeMutablePointer<Bool>?, _ count: Int32, _ sid: UInt64, _ visibleSid: UInt64) -> UInt64
{
    let (spaces, user) = spaceLists(spaceList, userList, count)
    return SpaceList.moveReplacement(spaces: spaces, user: user, sid: sid, visible: visibleSid)
}
