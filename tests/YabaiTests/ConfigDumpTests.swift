import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

//
// NOTE: `config --dump` (Sources/Yabai/IPC/ConfigDump.swift): the running config written as a yabai.toml. The dump reads back
// with ConfigDocument.decode, and reconciling the read-back document to the running state changes nothing. The per-space
// entries, the labels and the pins need a Mission Control index, which reads the window server, so the fixture (no
// displays, no spaces) cannot show them: they are checked live (the C6.2 live check of the static config plan). The suite is
// DaemonState, so the fixture resets the managers and the ConfigLoader before each test.
//

/// The changes and failures of reconciling every step to a document, as a reload does.
@WM private func reconcileSteps(_ document: ConfigDocument) -> ConfigReconcileResult {
  ConfigStep.allCases.reduce(into: ConfigReconcileResult()) {
    $0 += ConfigLoader.shared.reconcile(to: document, step: $1)
  }
}

/// The dump of the running config, as `config --dump` prints it.
@WM private func dumpText() -> String {
  String(decoding: Golden.run("config --dump"), as: UTF8.self)
}

/// The dump must pass `config --check`: a value that a handler rejects is a failure, and the report is the message.
@WM private func expectCleanDump(_ text: String, sourceLocation: SourceLocation = #_sourceLocation)
{
  let check = configFileCheck(path: "dump.toml", source: text)
  #expect(
    check.report.failures == 0, Comment(rawValue: check.report.text),
    sourceLocation: sourceLocation)
}

/// A file with a window gap, a rule, a rule with a label and a signal.
private let fileText = """
  [config]
  window_gap = 7

  [[rule]]
  app = "^Keep$"
  manage = false

  [[rule]]
  label = "other"
  app = "^Other$"

  [[signal]]
  event = "window_focused"
  action = "true"
  """

/// A file with a non-default value of each kind of option: a bool, an integer, a float, a color, a choice, a choice that
/// is also a string, an array of strings and a text.
private let kindsText = """
  [config]
  mouse_follows_focus = true
  window_gap = 7
  window_border_width = 2.5
  active_window_border_color = 0xffff0000
  window_shadow = "float"
  focus_follows_mouse = "autofocus"
  space_layout = ["bsp", "stack"]
  scratchpad_grid = "40:40:1:1:38:38"
  """

extension DaemonState {
  @Suite
  @WM struct ConfigDumpTests {
    @Test func aFreshDaemonDumpsADocumentThatReconcilesToNothing() throws {
      DaemonFixture.reset()
      let text = dumpText()

      expectCleanDump(text)
      let document = try ConfigDocument.decode(text)
      #expect(reconcileSteps(document) == ConfigReconcileResult())
      #expect(
        text.hasPrefix(
          "[daemon]\nauto_reload = true\nload_scripting_addition = false\n\n[config]\n"))
      #expect(text.contains("window_gap = 0 # default\n"))
      #expect(!text.contains("[[space]]"))
      #expect(!text.contains("[[rule]]"))
    }

    @Test func theDumpOfAppliedFileKeepsTheFileValuesWithoutComments() throws {
      DaemonFixture.reset()
      _ = reconcileSteps(try ConfigDocument.decode(fileText))
      _ = Headless.drain()

      let text = dumpText()
      expectCleanDump(text)
      #expect(text.contains("\nwindow_gap = 7\n"))
      #expect(text.contains("\n[[rule]]\napp = \"^Keep$\"\nmanage = false\n"))
      #expect(text.contains("\n[[rule]]\nlabel = \"other\"\napp = \"^Other$\"\n"))
      #expect(text.contains("\n[[signal]]\nevent = \"window_focused\"\naction = \"true\"\n"))
      #expect(!text.contains("# override"))
    }

    /// NOTE: A file with a value of each kind dumps clean and reconciles to nothing, so the dump writes every kind in a
    /// form that the handlers accept.
    @Test func aFileOfEveryKindDumpsCleanAndReconcilesToNothing() throws {
      DaemonFixture.reset()
      _ = reconcileSteps(try ConfigDocument.decode(kindsText))
      _ = Headless.drain()

      let text = dumpText()
      expectCleanDump(text)
      // NOTE: The values are checked too, so the test cannot pass with the file's values left unapplied.
      #expect(text.contains("\nmouse_follows_focus = true"))
      #expect(text.contains("\nwindow_gap = 7"))
      #expect(text.contains("\nwindow_border_width = 2.5"))
      #expect(text.contains("\nactive_window_border_color = 0xffff0000"))
      #expect(text.contains("\nwindow_shadow = \"float\""))
      #expect(text.contains("\nfocus_follows_mouse = \"autofocus\""))
      #expect(text.contains("\nscratchpad_grid = \"40:40:1:1:38:38\""))
      let document = try ConfigDocument.decode(text)
      #expect(reconcileSteps(document) == ConfigReconcileResult())
    }

    @Test func spaceAutoBackAndForthReadsBackFromTheDump() throws {
      DaemonFixture.reset()
      #expect(dumpText().contains("\nspace_auto_back_and_forth = false # default\n"))

      _ = reconcileSteps(try ConfigDocument.decode("[config]\nspace_auto_back_and_forth = true\n"))
      _ = Headless.drain()
      #expect(Config.current.space.autoBackAndForth)

      let text = dumpText()
      expectCleanDump(text)
      #expect(text.contains("\nspace_auto_back_and_forth = true\n"))
      #expect(reconcileSteps(try ConfigDocument.decode(text)) == ConfigReconcileResult())
    }

    /// NOTE: A value that the file does not give, changed at runtime, is an override; the others say default.
    @Test func aRuntimeChangeIsMarkedAsAnOverride() throws {
      DaemonFixture.reset()
      _ = reconcileSteps(try ConfigDocument.decode(fileText))
      _ = Headless.drain()

      #expect(Golden.run("config window_gap 99") == [])
      #expect(Golden.run("config mouse_follows_focus on") == [])
      let text = dumpText()
      #expect(text.contains("\nwindow_gap = 99 # override\n"))
      #expect(text.contains("\nmouse_follows_focus = true # override\n"))
      #expect(text.contains("\nfocus_follows_mouse = \"off\" # default\n"))
    }

    /// NOTE: The dump of the rules and signals that `rule --add` and `signal --add` store reads back as the same rules and
    /// signals, so reconciling it changes nothing.
    @Test func theRulesAndSignalsOfTheCommandsReadBackUnchanged() throws {
      DaemonFixture.reset()
      #expect(Golden.run("rule --add label=term app=Terminal sticky=on") == [])
      #expect(Golden.run("rule --add app=Notes grid=4:4:1:1:2:2 sub-layer=below") == [])
      #expect(Golden.run("rule --add --one-shot title=x manage=on") == [])
      #expect(Golden.run("rule --add app!=Finder manage=off scratchpad=notes") == [])
      #expect(
        Golden.run("signal --add event=window_moved app=^Foo$ active=yes action=echo_hi") == [])
      let before = runningRules()

      let text = dumpText()
      expectCleanDump(text)
      #expect(
        text.contains(
          "\n[[rule]]\nlabel = \"term\"\napp = \"Terminal\"\nsticky = true\n"))
      #expect(
        text.contains(
          "\n[[rule]]\napp = { not = \"Finder\" }\nmanage = false\nscratchpad = \"notes\"\n"))
      #expect(text.contains("active = true\n"))

      let document = try ConfigDocument.decode(text)
      #expect(reconcileSteps(document) == ConfigReconcileResult())
      #expect(runningRules() == before)
    }
  }
}

/// The rules and the signals of the running state, which a reconcile can change.
private struct RunningRules: Equatable {
  var rules: [Rule]
  var signals: SignalTable
}

@WM private func runningRules() -> RunningRules {
  RunningRules(rules: WindowManager.shared.rules.definitions, signals: EventSignals.shared.table)
}
