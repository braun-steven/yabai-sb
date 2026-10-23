import Foundation
import PropertyBased
import Testing
import YabaiTestSupport

@testable import Yabai
@testable import YabaiCore

//
// NOTE: The reconcile of the static config (ConfigReconcile.swift): a document is applied as the difference from the
// running state. The tests call ConfigLoader.reconcile for each step, as a reload does, and read the messages that ran
// from Headless. A space addressed by its index reads the window server (SpaceID(missionControlIndex:)), so the space
// tests use a label: the removal of an entry finds its space by that label. The suite is DaemonState, so the fixture
// resets the managers and the ConfigLoader before each test.
//

/// A display uuid that no display has: a pin to it is stored, and the query shows no display for it.
private let unknownDisplayUUID = "00000000-0000-0000-0000-000000000000"

/// A document with three options, two rules and a signal.
private let baseText = """
  [config]
  window_gap = 7
  mouse_follows_focus = true
  tab_bar_font = "Helvetica:14"

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

/// Parses a document of the tests, which the tests write as valid.
private func document(_ text: String) -> ConfigDocument {
  do {
    return try ConfigDocument.decode(text)
  } catch {
    fatalError("the test document does not decode: \(error)")
  }
}

/// Reconciles every step, as a reload does, and returns the number of messages that failed.
@WM private func reconcileAll(_ document: ConfigDocument) -> Int {
  ConfigStep.allCases.reduce(0) {
    $0 + ConfigLoader.shared.reconcile(to: document, step: $1).failures
  }
}

/// What a reconcile can change: the printed value of each option, and the rules and signals in their order.
private struct RunningState: Equatable {
  var options: [String]
  var rules: [Rule]
  var signals: SignalTable
}

@WM private func runningState() -> RunningState {
  RunningState(
    options: ConfigName.allCases.map { name in
      "\(name.rawValue)=\(printedConfigValue(["config", name.rawValue]) ?? "?")"
    },
    rules: WindowManager.shared.rules,
    signals: EventSignals.shared.table)
}

/// Random picks, read in order. Each pick is taken modulo its number of choices, and zero once the picks run out.
private struct ReconcilePicks {
  var values: [Int]
  var index = 0

  init(_ values: [Int]) { self.values = values }

  mutating func next(_ choices: Int) -> Int {
    guard index < values.count else { return 0 }
    defer { index += 1 }
    return values[index] % choices
  }

  mutating func bool() -> Bool { next(2) == 1 }
}

/// A small document from the picks: up to three options, two rules and two signals, and no spaces (see the NOTE above).
private func randomDocument(_ picks: inout ReconcilePicks) -> ConfigDocument {
  var document = ConfigDocument()
  if picks.bool() {
    document.options.append(
      ConfigOptionEntry(
        name: .windowGap, value: .integer(picks.next(10)), keyPath: "config.window_gap"))
  }
  if picks.bool() {
    document.options.append(
      ConfigOptionEntry(
        name: .mouseFollowsFocus, value: .bool(picks.bool()), keyPath: "config.mouse_follows_focus")
    )
  }
  if picks.bool() {
    let fonts = ["system:12", "Helvetica:14"]
    document.options.append(
      ConfigOptionEntry(
        name: .tabBarFont, value: .string(fonts[picks.next(fonts.count)]),
        keyPath: "config.tab_bar_font"))
  }

  for position in 0..<picks.next(3) {
    let apps = ["^Keep$", "^Drop$", "^Safari$"]
    var keys = [
      ConfigKey(
        name: "app", negated: false, value: .string(apps[picks.next(apps.count)]),
        keyPath: "rule[\(position)].app")
    ]
    if picks.bool() {
      let labels = ["a", "b"]
      keys.append(
        ConfigKey(
          name: "label", negated: false, value: .string(labels[picks.next(labels.count)]),
          keyPath: "rule[\(position)].label"))
    }
    if picks.bool() {
      keys.append(
        ConfigKey(
          name: "manage", negated: false, value: .bool(picks.bool()),
          keyPath: "rule[\(position)].manage"))
    }
    document.rules.append(RuleEntry(keys: keys, oneShot: false, keyPath: "rule[\(position)]"))
  }

  for position in 0..<picks.next(3) {
    let actions = ["true", "false"]
    let keys = [
      ConfigKey(
        name: "event", negated: false, value: .string("window_focused"),
        keyPath: "signal[\(position)].event"),
      ConfigKey(
        name: "action", negated: false, value: .string(actions[picks.next(actions.count)]),
        keyPath: "signal[\(position)].action"),
    ]
    document.signals.append(SignalEntry(keys: keys, keyPath: "signal[\(position)]"))
  }
  return document
}

extension DaemonState {
  @Suite
  @WM struct ConfigReconcileTests {
    @Test func anIdenticalDocumentRecordsNothing() {
      DaemonFixture.reset()
      let text = baseText
      #expect(reconcileAll(document(text)) == 0)
      _ = Headless.drain()

      #expect(reconcileAll(document(text)) == 0)
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func aFloatThePrintRoundsRecordsNothingOnTheSecondReconcile() {
      DaemonFixture.reset()
      let text = "[config]\nwindow_border_width = 2.123456\n"
      #expect(reconcileAll(document(text)) == 0)
      #expect(Golden.run("config window_border_width") == Array("2.1235\n".utf8))
      _ = Headless.drain()

      #expect(reconcileAll(document(text)) == 0)
      #expect(Headless.drain().configEntries.isEmpty)
    }

    @Test func aChangedGapChangesOnlyThatGap() {
      DaemonFixture.reset()
      _ = reconcileAll(document(baseText))
      _ = Headless.drain()

      let changed = baseText.replacingOccurrences(of: "window_gap = 7", with: "window_gap = 8")
      #expect(reconcileAll(document(changed)) == 0)
      #expect(Headless.drain().configEntries.map(\.arguments) == [["config", "window_gap", "8"]])
      #expect(Golden.run("config window_gap") == Array("8\n".utf8))
    }

    @Test func aRemovedOptionGoesBackToItsDefault() {
      DaemonFixture.reset()
      _ = reconcileAll(document("[config]\nwindow_gap = 7\n"))
      _ = Headless.drain()

      #expect(reconcileAll(document("[config]\n")) == 0)
      #expect(Golden.run("config window_gap") == Array("0\n".utf8))
      #expect(Headless.drain().configEntries.map(\.arguments) == [["config", "window_gap", "0"]])
    }

    @Test func aRuntimeOverrideIsFoundAndSetBackToTheFile() {
      DaemonFixture.reset()
      _ = reconcileAll(document(baseText))
      _ = Headless.drain()

      #expect(Golden.run("config window_gap 99") == [])
      #expect(reconcileAll(document(baseText)) == 0)
      #expect(Golden.run("config window_gap") == Array("7\n".utf8))
      #expect(Headless.drain().configEntries.map(\.arguments) == [["config", "window_gap", "7"]])
    }

    /// NOTE: A font that is not loaded is set even at its name (the guard of optionNeedsApply).
    @Test func aTabBarFontThatIsNotLoadedIsSetEvenAtItsName() {
      DaemonFixture.reset()
      WindowManager.shared.tabBarFont = nil
      #expect(reconcileAll(document("[config]\ntab_bar_font = \"system:12\"\n")) == 0)
      #expect(WindowManager.shared.tabBarFont != nil)
    }

    @Test func aReorderedRuleListReplacesTheList() {
      DaemonFixture.reset()
      let forward =
        "[[rule]]\napp = \"^a$\"\nmanage = false\n\n[[rule]]\napp = \"^b$\"\nmanage = false\n"
      let backward =
        "[[rule]]\napp = \"^b$\"\nmanage = false\n\n[[rule]]\napp = \"^a$\"\nmanage = false\n"
      _ = reconcileAll(document(forward))
      _ = Headless.drain()

      #expect(reconcileAll(document(forward)) == 0)
      #expect(Headless.drain().configEntries.isEmpty)

      #expect(reconcileAll(document(backward)) == 0)
      #expect(WindowManager.shared.rules.compactMap { $0.app?.text } == ["^b$", "^a$"])
      #expect(
        Headless.drain().configEntries.map(\.arguments) == [
          ["rule", "--add", "app=^b$", "manage=off"],
          ["rule", "--add", "app=^a$", "manage=off"],
        ])
    }

    @Test func aChangedSignalReplacesTheTable() {
      DaemonFixture.reset()
      _ = reconcileAll(document(baseText))
      _ = Headless.drain()

      let changed = baseText.replacingOccurrences(
        of: "action = \"true\"", with: "action = \"false\"")
      #expect(reconcileAll(document(changed)) == 0)
      #expect(EventSignals.shared.table.list().map(\.action) == ["false"])
      #expect(
        Headless.drain().configEntries.map(\.arguments) == [
          ["signal", "--add", "event=window_focused", "action=false"]
        ])
    }

    /// NOTE: The label of a removed space entry is found by its label, so the space needs no window server. The entry's
    /// pin, its label and its per-space gap go back to the global values.
    @Test func aRemovedSpaceEntryRemovesItsPinLabelAndSpaceValues() {
      DaemonFixture.reset()
      _ = Workspace()
      SpaceManager.shared.labels.set(id: Workspace.sid, name: "work")
      SpaceManager.shared.pins.pin(label: "work", toDisplay: unknownDisplayUUID)
      ConfigLoader.shared.applied = document(
        """
        [[space]]
        index = 1
        label = "work"
        pin = "1"
        window_gap = 30
        """)
      #expect(Golden.run("config --space work window_gap 30") == [])
      #expect(SpaceManager.shared.view(for: Workspace.sid).overrides.contains(.windowGap))

      #expect(ConfigLoader.shared.reconcile(to: document(""), step: .spaces).failures == 0)

      #expect(SpaceManager.shared.pins.isEmpty)
      #expect(SpaceManager.shared.labels.name(of: Workspace.sid) == nil)
      #expect(!SpaceManager.shared.view(for: Workspace.sid).overrides.contains(.windowGap))
      #expect(SpaceManager.shared.view(for: Workspace.sid).windowGap == 0)
    }

    /// NOTE: Whatever the applied document was, reconciling to a document ends in the state that a fresh start gives.
    @Test func reconcileEndsInTheStateOfAFreshStart() async {
      await propertyCheck(
        count: 60, input: Gen.int(in: 0...1_000_000).array(of: 0...40),
        Gen.int(in: 0...1_000_000).array(of: 0...40)
      ) { fromValues, toValues in
        var fromPicks = ReconcilePicks(fromValues)
        var toPicks = ReconcilePicks(toValues)
        let from = randomDocument(&fromPicks)
        let to = randomDocument(&toPicks)

        DaemonFixture.reset()
        #expect(reconcileAll(from) == 0)
        #expect(reconcileAll(to) == 0)
        let reconciled = runningState()

        DaemonFixture.reset()
        #expect(reconcileAll(to) == 0)
        #expect(runningState() == reconciled)
        _ = Headless.drain()
      }
    }

    @Test func sameValuesCompareAsTheyPrint() {
      let rows: [(printed: String, word: String, same: Bool)] = [
        ("0.000000", "0.0", true),
        ("4.0000", "4.0", true),
        ("4.0000", "4.5", false),
        ("0xff0000", "0x00ff0000", true),
        ("0xffe1e3e4", "0xffe1e3e4", true),
        ("0xff0000", "0x00fe0000", false),
        ("off", "on", false),
        ("system:12", "system:14", false),
        ("tree", "float", false),
        ("", "0", false),
        ("2.1235", "2.123456", true),
        ("2.1235", "2.2", false),
        ("0.250000", "0.25", true),
      ]
      for row in rows {
        #expect(sameConfigValue(row.printed, row.word) == row.same, "\(row)")
      }
    }
  }
}
