import Foundation
import Testing
import YabaiCore

@testable import Yabai

//
// NOTE: examples/skhdrc holds the binding-mode recipes. An skhd binding is `keys : command` (a mode is `:: name : command`),
// not a shell line, so extractYabaiCommands does not read the file as it is: for each binding the test takes the text
// from its first `yabai -m` on and extracts that as a script of its own. The reference bindings, commented out in the
// file, are checked too. A binding continued with a trailing backslash is left out: its only example is a shell pipeline
// with `$(…)`, which the extractor skips as dynamic. A `;` chain is split here before extraction, because the extractor
// marks a whole line that holds a `;` as dynamic. The window and space
// commands are not parsed by checkMessage (it adds a note for them), so they are parsed here by the pure parsers that
// their domain handlers use, and not run.
//

/// The path of examples/skhdrc in the repository.
private let recipesURL = URL(filePath: #filePath)
  .deletingLastPathComponent()  // tests/YabaiTests
  .deletingLastPathComponent()  // tests
  .deletingLastPathComponent()  // the repository
  .appending(path: "examples/skhdrc")

/// The command of each binding line of an skhd file, commented out or not: the text from the first `yabai -m` on, when
/// the text before it ends with `:`. `line` is the 1-based line of the binding.
private func skhdBindingCommands(_ text: String) -> [(line: Int, command: String)] {
  var commands: [(line: Int, command: String)] = []
  for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
  {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    if line.hasPrefix("#") {
      line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    guard !line.hasSuffix("\\"), let range = line.range(of: "yabai -m ") else { continue }
    let keys = line[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    guard keys.hasSuffix(":") else { continue }
    commands.append((index + 1, String(line[range.lowerBound...])))
  }
  return commands
}

/// The message the daemon reads for `arguments` (the words after `-m`, domain first): the length prefix is dropped.
private func clientMessage(_ arguments: [String]) -> Message {
  Message(arguments: arguments)
}

//
// NOTE: A leading `--` word is a command, never a selector. SpaceSelector takes any other word as a label, so the
// handler resolves `--focus` as a label first and, finding no space of that label, reads it as the command.
//

/// Whether a leading word of a domain message is a selector: a command word (`--…`) is not.
private func isSelectorWord(_ token: Token) -> Bool {
  !token.string.hasPrefix("--") && token.isValid
}

/// Parses the window commands of a message the way handleDomainWindow reads them: an optional leading selector, then
/// each command with its value. Nothing is run.
@WM private func parseWindowMessage(_ message: inout Message) throws(CommandError) {
  _ = message.next()
  var first = message.next()
  if isSelectorWord(first), WindowSelector(first) != nil { first = message.next() }
  while first.isValid {
    guard let name = WindowCommand.Name(token: first) else {
      throw CommandError.unknownCommand(Token(Domain.window), first)
    }
    _ = try WindowCommand.parse(name, &message)
    first = message.next()
  }
}

/// Parses the space commands of a message the way handleDomainSpace reads them: an optional leading selector, then each
/// command with its value. Nothing is run.
@WM private func parseSpaceMessage(_ message: inout Message) throws(CommandError) {
  _ = message.next()
  var command = message.next()
  if isSelectorWord(command), SpaceSelector(command) != nil { command = message.next() }
  while command.isValid {
    guard let name = SpaceCommand.Name(token: command) else {
      throw CommandError.unknownCommand(Token(Domain.space), command)
    }
    _ = try SpaceCommand.parse(name, &message)
    command = message.next()
  }
}

/// Whether the window or space commands of `arguments` parse. Nothing is run.
@WM private func parsesWithoutFailure(_ arguments: [String]) -> Bool {
  var message = clientMessage(arguments)
  do {
    if arguments.first == Domain.window.rawValue {
      try parseWindowMessage(&message)
    } else {
      try parseSpaceMessage(&message)
    }
    return true
  } catch {
    return false
  }
}

extension DaemonState {
  @Suite
  @WM struct SkhdRecipeTests {
    @Test func everyYabaiCommandOfTheRecipesIsValid() throws {
      let text = try String(contentsOf: recipesURL, encoding: .utf8)
      let bindings = skhdBindingCommands(text)
      // NOTE: An empty or unreadable file must fail here, not pass with nothing checked.
      #expect(bindings.count >= 40, "found \(bindings.count) bindings in \(recipesURL.path)")

      var checked = 0
      var windowCommands = 0
      var spaceCommands = 0
      for binding in bindings {
        // NOTE: Each `;` piece is one simple command, which the extractor reads as a line of its own.
        let pieces = binding.command.split(separator: ";").map { String($0) }
        let extracted = pieces.flatMap { extractYabaiCommands($0) }
        #expect(!extracted.isEmpty, "line \(binding.line): no yabai command in \(binding.command)")

        for command in extracted {
          guard let arguments = command.arguments else {
            Issue.record("line \(binding.line): not extracted: \(command.skipped ?? "unknown")")
            continue
          }
          checked += 1

          var message = clientMessage(arguments)
          let check = checkMessage(&message)
          #expect(
            check.failures.isEmpty,
            "line \(binding.line): \(arguments.joined(separator: " ")): \(check.failures)")

          if arguments.first == Domain.window.rawValue {
            windowCommands += 1
            var parsed = clientMessage(arguments)
            do {
              try parseWindowMessage(&parsed)
            } catch {
              Issue.record("line \(binding.line): \(arguments.joined(separator: " ")): \(error)")
            }
          } else if arguments.first == Domain.space.rawValue {
            spaceCommands += 1
            var parsed = clientMessage(arguments)
            do {
              try parseSpaceMessage(&parsed)
            } catch {
              Issue.record("line \(binding.line): \(arguments.joined(separator: " ")): \(error)")
            }
          }
        }
      }

      #expect(checked >= 50, "checked \(checked) commands")
      #expect(windowCommands >= 20, "checked \(windowCommands) window commands")
      #expect(spaceCommands >= 3, "checked \(spaceCommands) space commands")
    }

    @Test(arguments: [
      ["window", "--focuss", "west"],
      ["window", "--layout", "tabed"],
      ["window", "--insert", "wets"],
      ["space", "--balanse"],
      ["space", "--layout", "tabbed"],
    ])
    func aMisspelledWindowOrSpaceCommandFails(_ arguments: [String]) {
      #expect(!parsesWithoutFailure(arguments))
    }

    @Test(arguments: [
      ["window", "--focus", "west"],
      ["window", "--layout", "tabbed"],
      ["window", "--insert", "stack"],
      ["window", "--resize", "left:-20:0"],
      ["space", "--balance"],
      ["space", "--undo"],
      ["space", "--focus", "2"],
    ])
    func aCorrectWindowOrSpaceCommandParses(_ arguments: [String]) {
      #expect(parsesWithoutFailure(arguments))
    }
  }
}
