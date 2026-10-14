/// Pure functions over the space list of a display (the Mission Control order), from src/space_manager.c.
public enum SpaceList
{
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
