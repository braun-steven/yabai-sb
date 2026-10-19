import Testing
import CPrivate
import YabaiCore
@testable import Yabai

// NOTE: Ported from tests/src/message.c. Messages are null-separated tokens that end with an empty token, as sent by
// the client.

/// The result of a group of commands (nil when it threw), the failure text ("" when none) and whether the failure stops the message.
@WM private func runGroup(_ body: (inout Message) throws(CommandError) -> CommandResult, _ message: String) -> (CommandResult?, String, Bool)
{
    var source = Message(message)
    do {
        let result = try body(&source)
        return (result, "", false)
    } catch {
        return (nil, error.description, error.stopsMessage)
    }
}

@Test("message_window_layout_values")
func messageWindowLayoutValues()
{
    #expect(parseWindowLayout(Token("tabbed")) == .tabbed)
    #expect(parseWindowLayout(Token("toggle-split")) == .toggleSplit)
    #expect(parseWindowLayout(Token("stacked")) == nil)

    #expect(parseSplitOrientation(Token("vertical")) == .fixed(.vertical))
    #expect(parseSplitOrientation(Token("toggle")) == .toggle)
    #expect(parseSplitOrientation(Token("diagonal")) == nil)
}

@Test("message_window_command_groups")
@WM func messageWindowCommandGroups()
{
    let domain = Token(Domain.window)

    // NOTE: commands of other groups are left to them
    let (focus, focusText, _) = runGroup({ (source: inout Message) throws(CommandError) -> CommandResult in try windowCommandTree(domain, Token("--focus"), &source, nil) }, "\0")
    #expect(focus == .unknown)
    #expect(focusText.isEmpty)

    // NOTE: an invalid value stops the remaining commands of the message
    let (layout, layoutText, layoutStops) = runGroup({ (source: inout Message) throws(CommandError) -> CommandResult in try windowCommandTree(domain, Token("--layout"), &source, nil) }, "stacked\0")
    #expect(layout == nil)
    #expect(layoutText.contains("unknown value 'stacked' given to command '--layout'"))
    #expect(layoutStops)
}

@Test("message_space_command_groups")
@WM func messageSpaceCommandGroups()
{
    let domain = Token(Domain.space)

    let (focus, focusText, _) = runGroup({ (source: inout Message) throws(CommandError) -> CommandResult in try spaceCommandLayout(domain, Token("--focus"), &source, 1) }, "\0")
    #expect(focus == .unknown)
    #expect(focusText.isEmpty)

    let (rotate, rotateText, rotateStops) = runGroup({ (source: inout Message) throws(CommandError) -> CommandResult in try spaceCommandLayout(domain, Token("--rotate"), &source, 1) }, "45\0")
    #expect(rotate == nil)
    #expect(rotateText.contains("unknown value '45' given to command '--rotate'"))
    #expect(!rotateStops)

    let (mirror, mirrorText, mirrorStops) = runGroup({ (source: inout Message) throws(CommandError) -> CommandResult in try spaceCommandLayout(domain, Token("--mirror"), &source, 1) }, "z-axis\0")
    #expect(mirror == nil)
    #expect(mirrorText.contains("unknown value 'z-axis' given to command '--mirror'"))
    #expect(!mirrorStops)
}
