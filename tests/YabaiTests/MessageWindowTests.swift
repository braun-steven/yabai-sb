import Testing
import CPrivate
import YabaiCore
@testable import Yabai

// NOTE: Ported from tests/src/message.c. Messages are null-separated tokens that end with an empty token, as sent by
// the client.

private func runGroup(_ body: (inout Response, inout Message) -> CommandResult, _ message: String) -> (CommandResult, String)
{
    var response = Response()
    var source = Message(message)
    let result = body(&response, &source)
    return (result, response.text)
}

@Test("message_window_layout_values")
func messageWindowLayoutValues()
{
    #expect(parseWindowLayout(Token("tabbed")) == WINDOW_LAYOUT_TABBED)
    #expect(parseWindowLayout(Token("toggle-split")) == WINDOW_LAYOUT_TOGGLE_SPLIT)
    #expect(parseWindowLayout(Token("stacked")) == nil)

    #expect(parseSplitOrientation(Token("vertical")) == Int32(CON_VERTICAL.rawValue))
    #expect(parseSplitOrientation(Token("toggle")) == -1)
    #expect(parseSplitOrientation(Token("diagonal")) == nil)
}

@Test("message_window_command_groups")
func messageWindowCommandGroups()
{
    let domain = Token(Domain.window)

    // NOTE: commands of other groups are left to them
    let (focus, focusResponse) = runGroup({ windowCommandTree(&$0, domain, Token("--focus"), &$1, nil) }, "\0")
    #expect(focus == .unknown)
    #expect(focusResponse.isEmpty)

    // NOTE: an invalid value stops the remaining commands of the message
    let (layout, layoutResponse) = runGroup({ windowCommandTree(&$0, domain, Token("--layout"), &$1, nil) }, "stacked\0")
    #expect(layout == .stop)
    #expect(layoutResponse.contains("unknown value 'stacked' given to command '--layout'"))
}

@Test("message_space_command_groups")
func messageSpaceCommandGroups()
{
    let domain = Token(Domain.space)

    let (focus, _) = runGroup({ spaceCommandLayout(&$0, domain, Token("--focus"), &$1, 1) }, "\0")
    #expect(focus == .unknown)

    let (rotate, rotateResponse) = runGroup({ spaceCommandLayout(&$0, domain, Token("--rotate"), &$1, 1) }, "45\0")
    #expect(rotate == .done)
    #expect(rotateResponse.contains("unknown value '45' given to command '--rotate'"))

    let (mirror, mirrorResponse) = runGroup({ spaceCommandLayout(&$0, domain, Token("--mirror"), &$1, 1) }, "z-axis\0")
    #expect(mirror == .done)
    #expect(mirrorResponse.contains("unknown value 'z-axis' given to command '--mirror'"))
}
