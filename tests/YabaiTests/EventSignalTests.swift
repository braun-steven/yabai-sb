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
  var signal = EventSignal()
  signal.app = app.map { RulePattern(Token($0), exclude: false) }
  signal.title = title.map { RulePattern(Token($0), exclude: false) }
  signal.command = command
  return signal
}

@Test("event_signal_describe_spaces") @WM func eventSignalDescribeSpaces() {
  var es = PendingSignal(.spaceDestroyed)
  es.describeSpace(.space(1234))
  #expect(es.arguments.count == 1)
  #expect(es.arguments[0].name == "YABAI_SPACE_ID")
  #expect(es.arguments[0].value == "1234")

  var display = PendingSignal(.displayRemoved)
  display.describeDisplay(.display(5))
  #expect(display.arguments.count == 1)
  #expect(display.arguments[0].value == "5")
}

extension DaemonState {
  @Suite
  @WM struct EventSignalDispatchTests {
    @Test func dispatchFiltersEnvAndSubscribers() throws {
      DaemonFixture.reset()
      let recorder = SignalDispatchRecorder()
      let signals = EventSignals(
        runCommand: { recorder.run($0, arguments: $1) },
        publish: { recorder.publish($0, arguments: $1) })

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

      signals.push(.windowCreated, .window(target))
      signals.push(.configLoaded, .config(file: "/example/yabai.toml", changes: 4))
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

      signals.push(.windowCreated, .window(target))
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
