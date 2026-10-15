/// Pure functions over the space list of a display (the Mission Control order), from src/space_manager.c.
public enum SpaceList
{
    /// `space_list_index_of`: the position of sid in the list, nil when it is not there.
    public static func indexOf(spaces: [UInt64], sid: UInt64) -> Int?
    {
        spaces.firstIndex(of: sid)
    }

    //
    // NOTE: Returns the space offset positions from sid in the list, or 0 when sid is not in the list or
    // the position is outside of it.
    //

    /// `space_list_neighbour`
    public static func neighbour(spaces: [UInt64], sid: UInt64, offset: Int) -> UInt64
    {
        guard let index = indexOf(spaces: spaces, sid: sid) else { return 0 }

        let target = index + offset
        return spaces.indices.contains(target) ? spaces[target] : 0
    }

    /// `space_manager_move_space_replacement`: the user space that the scripting addition shows on the source
    /// display when sid moves to another display. Only a visible space needs one; it is the previous user space,
    /// else the next one, else 0.
    public static func moveReplacement(spaces: [UInt64], user: [Bool], sid: UInt64, visible: UInt64) -> UInt64
    {
        if sid != visible { return 0 }

        var prev: UInt64 = 0
        for i in spaces.indices {
            if spaces[i] == sid {
                if prev != 0 { return prev }

                for j in (i + 1)..<spaces.count {
                    if user[j] { return spaces[j] }
                }

                return 0
            }

            if user[i] { prev = spaces[i] }
        }

        return 0
    }
}
