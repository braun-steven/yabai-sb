import Synchronization
import Testing
import YabaiCore
@testable import Yabai

//
// NOTE: checkMessage (IPC/MessageCheck.swift) must find the failures handleMessage writes for the same message, byte for
// byte, and must change nothing. The suite is DaemonState: the comparison runs handleMessage too, which changes the
// managers. Rows with `executes: false` are not run by handleMessage here: it would resolve a space or display selector
// through SkyLight, change focus_follows_mouse or tab_bar_font, check SIP, or print a query. The check still finds their
// failures.
//

/// A message, the failure texts checkMessage must find for it, and whether handleMessage can run it in the test process.
struct CheckCase: CustomTestStringConvertible, Sendable
{
    let message: String
    let failures: [String]
    var executes = true

    var testDescription: String { message }
}

private let checkCases: [CheckCase] = [
    // config: valid values, queries and invalid values
    CheckCase(message: "config window_gap 10", failures: []),
    CheckCase(message: "config window_gap", failures: [], executes: false),
    CheckCase(message: "config window_gap x", failures: ["unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer\n"]),
    CheckCase(message: "config mouse_follows_focus maybe", failures: ["unknown value 'maybe' given to command 'mouse_follows_focus' for domain 'config'; expected on or off\n"]),
    CheckCase(message: "config debug_output on", failures: []),
    CheckCase(message: "config layout bogus", failures: ["unknown value 'bogus' given to command 'layout' for domain 'config'; expected one of: float, tree\n"]),
    CheckCase(message: "config layout tree", failures: []),
    CheckCase(message: "config focus_follows_mouse bogus", failures: ["unknown value 'bogus' given to command 'focus_follows_mouse' for domain 'config'; expected one of: off, autofocus, autoraise\n"]),
    CheckCase(message: "config focus_follows_mouse autoraise", failures: [], executes: false),
    CheckCase(message: "config tab_bar_height 0", failures: ["unknown value '0' given to command 'tab_bar_height' for domain 'config'; expected a positive integer\n"]),
    CheckCase(message: "config window_border_width 0", failures: ["unknown value '0' given to command 'window_border_width' for domain 'config'; expected a number above 0.0\n"]),
    CheckCase(message: "config active_window_border_color bogus", failures: ["unknown value 'bogus' given to command 'active_window_border_color' for domain 'config'; expected a hex color such as 0xffe1e3e4\n"]),
    CheckCase(message: "config scratchpad_grid 0:1:0:0:1:1", failures: ["unknown value '0:1:0:0:1:1' given to command 'scratchpad_grid' for domain 'config'; expected off or rows:columns:x:y:width:height, with rows and columns above 0\n"]),
    CheckCase(message: "config window_animation_duration bogus", failures: ["unknown value 'bogus' given to command 'window_animation_duration' for domain 'config'; expected a number of seconds (0 turns animations off)\n"]),
    CheckCase(message: "config window_animation_duration 1", failures: [], executes: false),
    CheckCase(message: "config tab_bar_font system:12", failures: [], executes: false),
    CheckCase(message: "config space_layout bogus", failures: ["unknown value 'bogus' given to command 'space_layout' for domain 'config'; expected off or one or more layouts such as 10:5 or 15 10:5:1b\n"]),
    CheckCase(message: "config bogus 1", failures: ["unknown command 'bogus' for domain 'config'\n", "unknown command '1' for domain 'config'\n"]),
    CheckCase(message: "config window_gap 10 mouse_follows_focus maybe", failures: ["unknown value 'maybe' given to command 'mouse_follows_focus' for domain 'config'; expected on or off\n"]),

    // config with --space: the selector is parsed, not resolved
    CheckCase(message: "config --space 1 window_gap 10", failures: [], executes: false),
    CheckCase(message: "config --space 1 space_layout 10", failures: ["command 'space_layout' for domain 'config' does not support the '--space' selector\n"], executes: false),
    CheckCase(message: "config --space 1 window_gap x", failures: ["unknown value 'x' given to command 'window_gap' for domain 'config'; expected a non-negative integer\n"], executes: false),

    // rule
    CheckCase(message: "rule --add label=term app=Terminal opacity=0.9 sticky=on", failures: []),
    CheckCase(message: "rule --add --one-shot title=x manage=on", failures: []),
    CheckCase(message: "rule --add app=Foo bogus=1", failures: ["unknown key 'bogus'\n"]),
    CheckCase(message: "rule --add app=(", failures: ["invalid regex pattern '(' for key 'app'\n"]),
    CheckCase(message: "rule --add label=üml app=x", failures: []),
    CheckCase(message: "rule --add", failures: ["missing required key-value pair 'app[!]=..' or 'title[!]=..'\n"]),
    CheckCase(message: "rule --apply", failures: []),
    CheckCase(message: "rule --apply nolabel", failures: ["invalid key-value pair 'nolabel'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"]),
    CheckCase(message: "rule --apply app=^NoSuchApp$ bogus=1", failures: ["unknown key 'bogus'\n"]),
    CheckCase(message: "rule --apply 7", failures: [], executes: false),
    CheckCase(message: "rule --remove 5", failures: [], executes: false),
    CheckCase(message: "rule --remove term", failures: [], executes: false),
    CheckCase(message: "rule --remove", failures: ["value '' is not a valid option for RULE_SEL\n"]),
    CheckCase(message: "rule --list", failures: [], executes: false),
    CheckCase(message: "rule --foo", failures: ["unknown command '--foo' for domain 'rule'\n"]),

    // signal
    CheckCase(message: "signal --add event=application_launched action=echo", failures: []),
    CheckCase(message: "signal --add action=echo", failures: ["missing required key-value pair 'event=..'\n"]),
    CheckCase(message: "signal --add event=bogus action=echo", failures: ["invalid value 'bogus' for key 'event'\n"]),
    CheckCase(message: "signal --remove 3", failures: [], executes: false),
    CheckCase(message: "signal --remove", failures: ["value '' is not a valid option for SIGNAL_SEL\n"]),
    CheckCase(message: "signal --list", failures: [], executes: false),
    CheckCase(message: "signal --foo", failures: ["unknown command '--foo' for domain 'signal'\n"]),

    // unknown domain
    CheckCase(message: "frobnicate --x", failures: ["unknown domain 'frobnicate'\n"]),
]

/// The state a check must leave alone: the config (dumped, since Config is a class), the debug flag, the rules and the
/// signals.
@WM private func stateSnapshot() -> String
{
    var text = ""
    dump(Config.current, to: &text)
    dump(Log.verbose.load(ordering: .relaxed), to: &text)
    dump(WindowManager.shared.rules, to: &text)
    dump(EventSignals.shared.table, to: &text)
    return text
}

/// Gives the managers a rule, a signal and a changed config, so that a check which changed them would show.
@WM private func seedState()
{
    for line in ["config window_gap 12", "rule --add label=term app=Terminal", "signal --add event=application_launched action=echo"] {
        var response = Response()
        var message = Golden.encode(line)
        handleMessage(&response, &message)
        #expect(response.bytes.isEmpty, "seed '\(line)' failed")
    }
}

extension DaemonState
{
    @Suite
    @WM struct MessageCheckTests
    {
        @Test(arguments: checkCases)
        func checkFindsTheFailures(_ row: CheckCase)
        {
            DaemonFixture.reset()
            var message = Golden.encode(row.message)
            let check = checkMessage(&message)
            #expect(check.failures == row.failures)
            #expect(check.notes.isEmpty)
        }

        //
        // NOTE: The failure texts of the check are the failure responses of handleMessage, byte for byte, the trailing
        // newline included. handleMessage writes each failure with the failure byte in front; the check writes nothing else.
        //

        @Test(arguments: checkCases.filter(\.executes))
        func checkMatchesHandleMessage(_ row: CheckCase)
        {
            DaemonFixture.reset()
            var checked = Golden.encode(row.message)
            let check = checkMessage(&checked)

            DaemonFixture.reset()
            var response = Response()
            var executed = Golden.encode(row.message)
            handleMessage(&response, &executed)

            #expect(response.text == check.failures.map { "\u{07}\($0)" }.joined())
        }

        @Test(arguments: checkCases)
        func checkChangesNothing(_ row: CheckCase)
        {
            DaemonFixture.reset()
            seedState()
            _ = Headless.drain()
            let before = stateSnapshot()

            var message = Golden.encode(row.message)
            _ = checkMessage(&message)

            #expect(stateSnapshot() == before)
            let sent = Headless.drain()
            #expect(sent.messages.isEmpty)
            #expect(sent.placements.isEmpty)
        }

        @Test(arguments: [
            ("space", "space --focus 1"),
            ("window", "window --focus east"),
            ("display", "display --focus 1"),
            ("query", "query --spaces"),
        ])
        func otherDomainsAreNotChecked(_ domain: String, _ message: String)
        {
            DaemonFixture.reset()
            var source = Golden.encode(message)
            let check = checkMessage(&source)
            #expect(check.failures.isEmpty)
            #expect(check.notes == ["not checked: \(domain) commands act on the current session"])
        }

        // Without a change the snapshot would show, checkChangesNothing would prove nothing.
        @Test func stateSnapshotSeesAChange()
        {
            DaemonFixture.reset()
            seedState()
            let before = stateSnapshot()

            var config = Golden.encode("config window_gap 10")
            var response = Response()
            handleMessage(&response, &config)
            #expect(stateSnapshot() != before)

            let configured = stateSnapshot()
            var removal = Golden.encode("rule --remove term")
            var removed = Response()
            handleMessage(&removed, &removal)
            #expect(stateSnapshot() != configured)
        }

        // A rule --apply with a label that exists ignores the inline values that do not parse, as handleDomainRule does.
        @Test func ruleApplyWithAnExistingLabelIgnoresInlineFailures()
        {
            DaemonFixture.reset()
            seedState()

            var existing = Golden.encode("rule --apply term bogus=1")
            #expect(checkMessage(&existing).failures.isEmpty)
            var executed = Golden.encode("rule --apply term bogus=1")
            var response = Response()
            handleMessage(&response, &executed)
            #expect(response.bytes.isEmpty)

            var missing = Golden.encode("rule --apply nolabel bogus=1")
            #expect(checkMessage(&missing).failures == ["invalid key-value pair 'nolabel'\nunknown key 'bogus'\nmissing required key-value pair 'app[!]=..' or 'title[!]=..'\n"])
        }

        // Index and label lookups need the current rules and signals: the check does not report them, handleMessage does.
        @Test func notFoundFailuresAreLeftToHandleMessage()
        {
            DaemonFixture.reset()
            var checked = Golden.encode("rule --remove 5")
            #expect(checkMessage(&checked).failures.isEmpty)

            var response = Response()
            var executed = Golden.encode("rule --remove 5")
            handleMessage(&response, &executed)
            #expect(response.text == "\u{07}rule with index '5' not found.\n")
        }
    }
}
