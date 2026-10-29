import Foundation
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

// NOTE: A destroyed space and a removed display are described by their id alone, without the managers.

private struct RecordedSignalArgument: Equatable {
  let name: String
  let value: String
}

private struct RecordedCommand: Equatable {
  let command: String
  let arguments: [RecordedSignalArgument]
}

private struct PublishedSignal: Equatable {
  let type: SignalType
  let arguments: [RecordedSignalArgument]
}

@WM private final class SignalDispatchRecorder {
  var commands: [RecordedCommand] = []
  var published: [PublishedSignal] = []

  func run(_ command: String, arguments: [(name: String, value: String)]) {
    commands.append(
      RecordedCommand(
        command: command,
        arguments: arguments.map { RecordedSignalArgument(name: $0.name, value: $0.value) }))
  }

  func publish(_ type: SignalType, arguments: [(name: String, value: String)]) {
    published.append(
      PublishedSignal(
        type: type,
        arguments: arguments.map { RecordedSignalArgument(name: $0.name, value: $0.value) }))
  }
}

private func dispatchSignal(app: String? = nil, title: String? = nil, command: String)
  -> EventSignal
{
  var signal = EventSignal(command: command)
  signal.app = app.map { RulePattern(Token($0), exclude: false) }
  signal.title = title.map { RulePattern(Token($0), exclude: false) }
  return signal
}

@Test("event_signal_describe_spaces") @WM func eventSignalDescribeSpaces() {
  let es = SignalEvent.spaceDestroyed(SpaceID(0xFFFF_0000)).snapshot()
  #expect(es.arguments.count == 1)
  #expect(es.arguments[0].name == "YABAI_SPACE_ID")
  #expect(es.arguments[0].value == "4294901760")

  let display = SignalEvent.displayRemoved(DisplayID(0xFFFF_0000)).snapshot()
  #expect(display.arguments.count == 1)
  #expect(display.arguments[0].value == "-65536")
}

extension DaemonState {
  @Suite
  @WM struct EventSignalDispatchTests {
    @Test func dispatchFiltersEnvAndSubscribers() throws {
      DaemonFixture.reset()
      let recorder = SignalDispatchRecorder()
      let signals = EventSignals(
        runCommand: { recorder.run($0, arguments: $1) },
        publish: { recorder.publish($0, arguments: $1) },
        subscriberInterest: { _ in false })

      signals.table.add(
        dispatchSignal(app: "^Terminal$", title: "^Report\\.md$", command: "filtered-app"),
        .windowCreated)
      signals.table.add(
        dispatchSignal(app: "^Editor$", title: "^Other$", command: "filtered-title"),
        .windowCreated)
      signals.table.add(
        dispatchSignal(app: "^Editor$", title: "^Report\\.md$", command: "first"),
        .windowCreated)
      signals.table.add(
        dispatchSignal(app: "^Editor$", title: "^Report\\.md$", command: "second"),
        .windowCreated)
      signals.table.add(dispatchSignal(command: "config"), .configLoaded)

      let target = Window(id: WindowID(rawValue: 0xFFFF_00A1))
      let application = Application()
      application.name = "Editor"
      target.application = application
      target.ax.title = "Report.md"

      signals.push(.windowCreated(target))
      signals.push(.configLoaded(file: "/example/yabai.toml", changes: 4))
      signals.flush()

      let commands = recorder.commands
      let published = recorder.published
      #expect(commands.map(\.command) == ["first", "second", "config"])
      let firstCommand = try #require(commands.first)
      let configCommand = try #require(commands.dropFirst(2).first)
      let configPublished = try #require(published.dropFirst().first)
      #expect(
        firstCommand.arguments == [
          RecordedSignalArgument(
            name: "YABAI_WINDOW_ID", value: "\(Int32(bitPattern: target.id.rawValue))")
        ])
      #expect(
        configCommand.arguments == [
          RecordedSignalArgument(name: "YABAI_CONFIG_FILE", value: "/example/yabai.toml"),
          RecordedSignalArgument(name: "YABAI_CONFIG_CHANGES", value: "4"),
        ])
      #expect(published.map(\.type) == [.windowCreated, .configLoaded])
      #expect(configPublished.arguments == configCommand.arguments)

      recorder.commands = []
      recorder.published = []
      signals.table = SignalTable()
      signals.table.add(
        dispatchSignal(app: "^Terminal$", title: "^Report\\.md$", command: "filtered-app"),
        .windowCreated)
      signals.table.add(
        dispatchSignal(app: "^Editor$", title: "^Other$", command: "filtered-title"),
        .windowCreated)

      signals.push(.windowCreated(target))
      signals.flush()

      #expect(recorder.commands.isEmpty)
      #expect(recorder.published.map(\.type) == [.windowCreated])
      let filteredPublication = try #require(recorder.published.first)
      #expect(
        filteredPublication.arguments == [
          RecordedSignalArgument(
            name: "YABAI_WINDOW_ID", value: "\(Int32(bitPattern: target.id.rawValue))")
        ])
    }
  }
}

@Test(arguments: [-1, 0, 1])
func signalTerminationFocusUsesTheExactThreshold(offset: Int) {
  let threshold = Double(Float(0.05))
  let elapsed = offset < 0 ? threshold.nextDown : offset > 0 ? threshold.nextUp : threshold
  #expect(
    SignalEvent.terminationWasActive(pid: 7, frontPID: 7, lastFrontPID: 8, elapsed: elapsed)
      == (offset >= 0))
  #expect(
    SignalEvent.terminationWasActive(pid: 8, frontPID: 7, lastFrontPID: 8, elapsed: elapsed)
      == (offset < 0))
}

extension DaemonState.EventSignalDispatchTests {
  @Test func subscriberOnlyCaptureIsIsolatedAndSkipsUnwantedEvents() {
    let recorder = SignalDispatchRecorder()
    let signals = EventSignals(
      runCommand: { recorder.run($0, arguments: $1) },
      publish: { recorder.publish($0, arguments: $1) },
      subscriberInterest: { $0 == .spaceDestroyed })
    // Creating a space snapshot would query WindowServer, so rejecting it also checks the early gate.
    signals.push(.spaceCreated(SpaceID(0xFFFF_0000)))
    #expect(signals.pending.isEmpty)
    signals.push(.spaceDestroyed(SpaceID(0xFFFF_0000)))
    #expect(signals.pending.count == 1)
    signals.flush()
    signals.flush()
    #expect(recorder.commands.isEmpty)
    #expect(recorder.published.map(\.type) == [.spaceDestroyed])
    #expect(EventSubscribers.shared.subscribers.isEmpty)
  }

  @Test func windowCaptureKeepsValuesAfterTheModelChanges() throws {
    let recorder = SignalDispatchRecorder()
    let signals = EventSignals(
      runCommand: { recorder.run($0, arguments: $1) },
      publish: { recorder.publish($0, arguments: $1) },
      subscriberInterest: { _ in false })
    signals.table.add(
      dispatchSignal(app: "^Editor$", title: "^Before$", command: "run"), .windowMoved)
    let window = Window(id: WindowID(0xFFFF_0000))
    let application = Application()
    application.name = "Editor"
    window.application = application
    window.ax.title = "Before"
    WindowManager.shared.focus.focusChanged(to: window.id)
    signals.push(.windowMoved(window))
    let snapshot = try #require(signals.pending.first)
    #expect(snapshot.active)
    #expect(snapshot.arguments.map(\.value) == ["-65536"])
    application.name = "Changed"
    window.ax.title = "After"
    window.application = nil
    WindowManager.shared.focus.focusChanged(to: nil)
    signals.flush()
    #expect(recorder.commands.map(\.command) == ["run"])
    #expect(recorder.published.map(\.type) == [.windowMoved])
  }

  @Test func destroyedWindowHasReducedMetadataAndHandlesMissingApplication() {
    let window = Window(id: WindowID(0xFFFF_0000))
    window.ax.title = "No longer safe to query"
    WindowManager.shared.focus.focusChanged(to: window.id)
    let missingApp = SignalEvent.windowDestroyed(window).snapshot()
    #expect(missingApp.app == "<unknown>")
    #expect(missingApp.title == nil)
    #expect(missingApp.active)
    #expect(missingApp.arguments.map(\.value) == ["-65536"])
    let application = Application()
    application.name = "Editor"
    window.application = application
    #expect(SignalEvent.windowDestroyed(window).snapshot().app == "Editor")
  }

  @Test func applicationCapturePreservesHiddenAndTerminationMetadata() {
    let pm = ProcessManager.shared
    let previous = (pm.frontPID, pm.lastFrontPID, pm.switchEventTime)
    defer { (pm.frontPID, pm.lastFrontPID, pm.switchEventTime) = previous }
    let application = Application()
    application.pid = 123_456_789
    application.name = "Editor"
    pm.frontPID = application.pid
    pm.lastFrontPID = 123_456_790
    pm.switchEventTime = 0
    let hidden = SignalEvent.applicationHidden(application).snapshot()
    let terminated = SignalEvent.applicationTerminated(application).snapshot()
    for snapshot in [hidden, terminated] {
      #expect(snapshot.app == "Editor")
      #expect(snapshot.title == nil)
      #expect(snapshot.active)
      #expect(snapshot.arguments.map(\.name) == ["YABAI_PROCESS_ID"])
      #expect(snapshot.arguments.map(\.value) == ["123456789"])
    }
    pm.frontPID = 123_456_790
    #expect(!SignalEvent.applicationHidden(application).snapshot().active)
  }

  @Test func typedEventsKeepThePublicTypeOrder() {
    let app = Application()
    let window = Window(id: WindowID(0xFFFF_0000))
    let space = SpaceID(0xFFFF_0000)
    let display = DisplayID(0xFFFF_0000)
    let events: [SignalEvent] = [
      .applicationLaunched(app), .applicationTerminated(app), .applicationFrontSwitched,
      .applicationActivated(app), .applicationDeactivated(app), .applicationVisible(app),
      .applicationHidden(app), .windowCreated(window), .windowDestroyed(window),
      .windowFocused(window), .windowMoved(window), .windowResized(window),
      .windowMinimized(window),
      .windowDeminimized(window), .windowTitleChanged(window), .spaceCreated(space),
      .spaceDestroyed(space), .spaceChanged, .displayAdded(display), .displayRemoved(display),
      .displayMoved(display), .displayResized(display), .displayChanged,
      .missionControlEnter(.show),
      .missionControlExit(.inactive), .dockDidChangePref, .dockDidRestart, .menuBarHiddenChanged,
      .systemWoke, .configLoaded(file: "/example/yabai.toml", changes: 0),
    ]
    #expect(events.map(\.type) == SignalType.allCases)
  }

  @Test func missionControlConfigAndSystemSnapshotsKeepTheirArguments() {
    let enter = SignalEvent.missionControlEnter(.showDesktop).snapshot()
    #expect(enter.arguments.map(\.name) == ["YABAI_MISSION_CONTROL_MODE"])
    #expect(enter.arguments.map(\.value) == ["show-desktop"])
    #expect(
      SignalEvent.missionControlExit(.inactive).snapshot().arguments.map(\.value) == ["inactive"])
    let config = SignalEvent.configLoaded(file: "/example/yabai.toml", changes: 3).snapshot()
    #expect(config.arguments.map(\.name) == ["YABAI_CONFIG_FILE", "YABAI_CONFIG_CHANGES"])
    #expect(config.arguments.map(\.value) == ["/example/yabai.toml", "3"])
    let system: [SignalEvent] = [
      .dockDidRestart, .dockDidChangePref, .menuBarHiddenChanged, .systemWoke,
    ]
    #expect(system.allSatisfy { $0.snapshot().arguments.isEmpty })
  }
}

//
// NOTE: The process of a signal command. These start a real shell but touch no manager, so they are outside
// DaemonState. The child writes what it saw to a report pipe that the test keeps open in it, as the daemon keeps stdout.
//

@Suite struct EventSignalProcessTests {
  /// A descriptor that is not close-on-exec yet (a socket before its fcntl) stays out of the command; stdio stays in.
  @Test func aCommandKeepsItsStdioAndNoOtherDescriptor() async throws {
    var leaked: [Int32] = [-1, -1]
    var report: [Int32] = [-1, -1]
    try #require(pipe(&leaked) == 0)
    try #require(pipe(&report) == 0)
    defer { for descriptor in leaked + [report[0]] { close(descriptor) } }
    _ = fcntl(report[0], F_SETFD, FD_CLOEXEC)
    _ = fcntl(report[1], F_SETFD, FD_CLOEXEC)
    let stdio = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
    let script = """
      open=""; for fd in 0 1 2 "$LEAKED"; do if [ -e /dev/fd/$fd ]; then open="$open $fd"; fi; done
      echo "$YABAI_TEST_VALUE$open" > /dev/fd/$REPORT
      """
    let arguments = [
      (name: "YABAI_TEST_VALUE", value: "seen"), (name: "LEAKED", value: "\(leaked[1])"),
      (name: "REPORT", value: "\(report[1])"),
    ]
    let spawned = EventSignals.spawn(script, arguments, keeping: stdio + [report[1]])
    close(report[1])
    let pid = try #require(spawned)
    let reader = report[0]
    // NOTE: Waits for the child, then reads its one short write, so a sibling test's child holding the writer cannot
    // delay an end of file. A child that writes nothing reads as an end of file, since the test closed its writer.
    let text = await onThread { () -> String in
      var status: Int32 = 0
      _ = waitpid(pid, &status, 0)
      var buffer = [UInt8](repeating: 0, count: 256)
      let count = read(reader, &buffer, buffer.count)
      return count > 0 ? String(decoding: buffer[..<count], as: UTF8.self) : ""
    }
    let open = stdio.filter { fcntl($0, F_GETFD) != -1 }.map { " \($0)" }.joined()
    #expect(text == "seen\(open)\n")
  }
}
