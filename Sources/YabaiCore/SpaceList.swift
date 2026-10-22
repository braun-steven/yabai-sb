/// Pure functions over the space list of a display (the Mission Control order).
public enum SpaceList {
  /// The position of sid in the list, nil when it is not there.
  public static func indexOf(spaces: [SpaceID], sid: SpaceID) -> Int? {
    spaces.firstIndex(of: sid)
  }

  //
  // NOTE: Returns the space offset positions from sid in the list, or nil when sid is not in the list or
  // the position is outside of it.
  //

  /// The space that is `offset` positions from sid in the list.
  public static func neighbour(spaces: [SpaceID], sid: SpaceID, offset: Int) -> SpaceID? {
    guard let index = indexOf(spaces: spaces, sid: sid) else { return nil }

    let target = index + offset
    return spaces.indices.contains(target) ? spaces[target] : nil
  }

  /// The user space that the scripting addition shows on the source
  /// display when sid moves to another display. Only a visible space needs one; it is the previous user space,
  /// else the next one, else nil.
  public static func moveReplacement(
    spaces: [SpaceID], user: [Bool], sid: SpaceID, visible: SpaceID
  ) -> SpaceID? {
    if sid != visible { return nil }

    var prev: SpaceID? = nil
    for i in spaces.indices {
      if spaces[i] == sid {
        if let prev { return prev }

        for j in (i + 1)..<spaces.count {
          if user[j] { return spaces[j] }
        }

        return nil
      }

      if user[i] { prev = spaces[i] }
    }

    return nil
  }
}
