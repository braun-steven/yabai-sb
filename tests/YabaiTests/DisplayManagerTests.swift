import Testing
@testable import Yabai
import YabaiTestSupport

@Suite struct DisplayManagerTests
{
    static let builtinLastRows: [([String], Bool, [String])] = [
        (["builtin", "a", "b"], true, ["a", "b", "builtin"]),
        (["a", "builtin", "b"], true, ["a", "b", "builtin"]),
        (["a", "b", "builtin"], true, ["a", "b", "builtin"]),
        // only the first builtin display moves
        (["builtin", "builtin", "a"], true, ["builtin", "a", "builtin"]),
        (["a", "b"], true, ["a", "b"]),
        (["builtin"], true, ["builtin"]),
        ([], true, []),
        (["builtin", "a", "b"], false, ["builtin", "a", "b"]),
    ]

    @Test(arguments: builtinLastRows)
    func builtinDisplayMovesLast(_ list: [String], _ enabled: Bool, _ expected: [String])
    {
        #expect(DisplayManager.orderedBuiltinLast(list, enabled: enabled) { $0 == "builtin" } == expected)
    }
}
