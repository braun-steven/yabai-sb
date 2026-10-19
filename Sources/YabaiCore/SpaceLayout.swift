//
// NOTE: space_layout keeps a number of user spaces per display, chosen by the number of displays. When the
// displays change, reconcile passes move, create or destroy one space each until the counts match.
// This is the pure part; the reconcile passes are Sources/Yabai/SpaceLayout.swift.
//

/// The number of user spaces per display, for one display count (`count`). builtinIndex is the entry for the
/// builtin display ('b' suffix).
public struct SpaceLayout: Equatable, Sendable
{
    /// The most layouts `space_layout` takes, and the most displays it lays out.
    public static let max = 8

    public var target: [Int]
    public var builtinIndex: Int?

    public var count: Int { target.count }

    public init(target: [Int], builtinIndex: Int? = nil)
    {
        self.target = target
        self.builtinIndex = builtinIndex
    }

    /// `space_layout_parse`: a spec like "10:5:1b".
    public init?(parsing text: some Collection<UInt8>)
    {
        let text = Array(text)
        let length = text.count
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9")

        target = []
        builtinIndex = nil

        var i = 0
        while i < length {
            if count == SpaceLayout.max { return nil }

            var value = 0
            var digits = 0
            while i < length && text[i] >= zero && text[i] <= nine {
                value = value * 10 + Int(text[i] - zero)
                if value > 1000 { return nil }
                digits += 1
                i += 1
            }
            if digits == 0 || value < 1 { return nil }

            if i < length && text[i] == UInt8(ascii: "b") {
                if builtinIndex != nil { return nil }
                builtinIndex = count
                i += 1
            }

            target.append(value)

            if i < length {
                if text[i] != UInt8(ascii: ":") || i + 1 == length { return nil }
                i += 1
            }
        }

        if count == 0 { return nil }
    }

    public init?(parsing text: String)
    {
        self.init(parsing: text.utf8)
    }

    /// `space_layout_targets`: the target of each display in arrangement order, where builtin is the index of
    /// the builtin display. The builtin entry goes to the builtin display, the others keep their order.
    public func targets(builtin: Int?) -> [Int]
    {
        guard let builtinIndex, let builtin else { return target }

        var result = [Int](repeating: 0, count: count)
        result[builtin] = target[builtinIndex]

        var j = 0
        for i in 0..<count {
            if i == builtin { continue }
            if j == builtinIndex { j += 1 }
            result[i] = target[j]
            j += 1
        }

        return result
    }

    /// `space_layout_move_candidate`: the space a reconcile pass moves off a display with too many spaces. It is
    /// the first user space from the given edge that is not visible, else the visible space when it is the only
    /// user space, else nil.
    public static func moveCandidate(spaces: [SpaceID], user: [Bool], visible: SpaceID?, fromEnd: Bool) -> SpaceID?
    {
        let count = spaces.count

        for k in 0..<count {
            let i = fromEnd ? count - 1 - k : k
            if user[i] && spaces[i] != visible { return spaces[i] }
        }

        for i in 0..<count {
            if user[i] && spaces[i] == visible { return visible }
        }

        return nil
    }
}
