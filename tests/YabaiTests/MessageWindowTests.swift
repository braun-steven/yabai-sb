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
