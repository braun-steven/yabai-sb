import Darwin

//
// NOTE: The commands of the window domain, parsed from their tokens. The daemon runs them against the acting window
// (MessageWindow.swift) and resolves their selectors then. A message is parsed one command at a time, each after the
// previous one ran, so a failing command still lets the next one run unless its failure stops the message.
//

/// The axis along which a split container places its children.
public enum ConOrientation: Sendable {
  case horizontal
  case vertical
}

/// A value of `window --layout`, named by its token.
public enum WindowLayout: String, CaseIterable, Sendable {
  case tabbed
  case split
  case toggle
  case splitH = "splith"
  case splitV = "splitv"
  case toggleSplit = "toggle-split"
}

/// The orientation of `window --split`: a fixed one, or across the orientation of the parent container (`toggle`).
public enum SplitOrientation: Equatable, Sendable {
  case fixed(ConOrientation)
  case toggle

  public init?(_ token: Token) {
    if token.equals("horizontal") {
      self = .fixed(.horizontal)
    } else if token.equals("vertical") {
      self = .fixed(.vertical)
    } else if token.equals("toggle") {
      self = .toggle
    } else {
      return nil
    }
  }
}

/// What `window --focus` selects: a window, or a container of the tree of the acting window.
public enum WindowFocusTarget: Equatable, Sendable {
  case window(WindowSelector?)
  /// A direction, parent or child; the daemon focuses a container when the acting window is in a tree.
  case container(TreeFocus)

  /// What the target selects when the acting window is in no tree: a direction selects the window in that direction,
  /// parent and child are no window selectors.
  public func windowSelector() throws(CommandError) -> WindowSelector? {
    switch self {
    case .window(let selector): return selector
    case .container(.direction(let side)): return .direction(side)
    case .container(.parent): throw WindowSelector.invalid(Token(Argument.parent))
    case .container(.child): throw WindowSelector.invalid(Token(Argument.child))
    }
  }
}

/// What `window --scratchpad` does with the acting window.
public enum ScratchpadAction: Equatable, Sendable {
  /// `recover`: shows and unfloats the windows of every scratchpad.
  case recover
  case assign(label: String)
  /// No label: the window leaves its scratchpad.
  case remove
}

/// A command of the window domain with its value.
public enum WindowCommand: Equatable, Sendable {
  case focus(WindowFocusTarget)
  case close(WindowSelector?)
  case minimize(WindowSelector?)
  case deminimize(WindowSelector)
  case display(DisplaySelector)
  case space(SpaceSelector)
  case swap(WindowSelector)
  case warp(WindowSelector)
  case stack(WindowSelector)
  case layout(WindowLayout)
  case split(SplitOrientation)
  case insert(InsertDirection)
  case grid(Grid)
  /// The type is nil for an unknown type, which the move ignores.
  case move(ValueType?, dx: Float, dy: Float)
  /// The handle is empty for an unknown handle.
  case resize(ResizeHandle, dx: Float, dy: Float)
  /// The type is nil for an unknown type.
  case ratio(ValueType?, Float)
  case toggle(WindowToggle)
  /// `--toggle` with a value that is no window property: a scratchpad label.
  case toggleScratchpad(Token)
  case subLayer(WindowLayer)
  case opacity(Float)
  case raise(WindowSelector?)
  case lower(WindowSelector?)
  case scratchpad(ScratchpadAction)

  /// The name of a command, its first token.
  public enum Name: String, CaseIterable, Sendable {
    case focus = "--focus"
    case close = "--close"
    case minimize = "--minimize"
    case deminimize = "--deminimize"
    case display = "--display"
    case space = "--space"
    case swap = "--swap"
    case warp = "--warp"
    case stack = "--stack"
    case insert = "--insert"
    case grid = "--grid"
    case move = "--move"
    case resize = "--resize"
    case ratio = "--ratio"
    case subLayer = "--sub-layer"
    case opacity = "--opacity"
    case raise = "--raise"
    case lower = "--lower"
    case toggle = "--toggle"
    case scratchpad = "--scratchpad"
    case layout = "--layout"
    case split = "--split"

    /// Whether the command needs an acting window. The others select their window, or need none (a scratchpad
    /// toggle).
    public var needsWindow: Bool {
      switch self {
      case .focus, .close, .minimize, .deminimize, .toggle: false
      default: true
      }
    }
  }

  /// The failure of a command given a value it does not accept; `expected` names the values it takes.
  public static func unknownValue(_ name: Name, _ value: Token, expected: String) -> CommandError {
    CommandError.unknownValue(Token(Domain.window), Token(name.rawValue), value, expected: expected)
  }

  //
  // NOTE: Every command takes the next token as its value, even when it is missing or is the next command. An
  // optional selector that is invalid stops the message, a required one does not; an invalid --layout or --split
  // value stops it too.
  //

  /// Parses the value of the command name from the message.
  public static func parse(_ name: Name, _ message: inout some TokenSource) throws(CommandError)
    -> WindowCommand
  {
    let value = message.next()

    switch name {
    case .focus:
      if let focus = TreeFocus(value) { return .focus(.container(focus)) }
      return .focus(.window(try optionalSelector(value)))
    case .close:
      return .close(try optionalSelector(value))
    case .minimize:
      return .minimize(try optionalSelector(value))
    case .deminimize:
      return .deminimize(try WindowSelector.required(value))
    case .display:
      return .display(try DisplaySelector.required(value))
    case .space:
      return .space(try SpaceSelector.required(value))
    case .swap:
      return .swap(try WindowSelector.required(value))
    case .warp:
      return .warp(try WindowSelector.required(value))
    case .stack:
      return .stack(try WindowSelector.required(value))
    case .insert:
      return .insert(try parseInsertSelector(value))
    case .grid:
      var grid = Grid()
      guard grid.parse(value) else {
        throw unknownValue(name, value, expected: "six integers as rows:columns:x:y:width:height")
      }
      return .grid(grid)
    case .move:
      let scan = value.scanFloats(field: 255, count: 2)
      guard scan.assigned == 3, let type = scan.field, scan.values.allSatisfy(\.isFinite) else {
        throw unknownValue(name, value, expected: "abs or rel, then two numbers, e.g. rel:10:-5")
      }
      return .move(parseValueType(type), dx: scan.values[0], dy: scan.values[1])
    case .resize:
      let scan = value.scanFloats(field: 255, count: 2)
      guard scan.assigned == 3, let handle = scan.field, scan.values.allSatisfy(\.isFinite) else {
        throw unknownValue(
          name, value,
          expected:
            "a handle (top, bottom, left, right, top_left, top_right, bottom_left, bottom_right or abs), then two numbers, e.g. top_left:10:-5"
        )
      }
      return .resize(parseResizeHandle(handle), dx: scan.values[0], dy: scan.values[1])
    case .ratio:
      let scan = value.scanFloats(field: 255, count: 1)
      guard scan.assigned == 2, let type = scan.field, scan.values[0].isFinite else {
        throw unknownValue(name, value, expected: "abs or rel, then a number, e.g. abs:0.5")
      }
      return .ratio(parseValueType(type), scan.values[0])
    case .subLayer:
      guard let layer = parseLayer(value) else {
        throw unknownValue(
          name, value, expected: expectedChoices(WindowLayer.allCases.map(\.rawValue)))
      }
      return .subLayer(layer)
    case .opacity:
      guard let opacity = value.value.floatValue, opacity >= 0.0 && opacity <= 1.0 else {
        throw unknownValue(name, value, expected: "a number from 0.0 to 1.0")
      }
      return .opacity(opacity)
    case .raise:
      return .raise(try optionalSelector(value))
    case .lower:
      return .lower(try optionalSelector(value))
    case .toggle:
      if let toggle = WindowToggle(token: value) { return .toggle(toggle) }
      return .toggleScratchpad(value)
    case .scratchpad:
      if value.isValid && value.equals(Argument.recover) { return .scratchpad(.recover) }
      if let label = try parseLabel(value, .window) {
        return .scratchpad(.assign(label: label.string))
      }
      return .scratchpad(.remove)
    case .layout:
      guard let layout = WindowLayout(token: value) else {
        throw unknownValue(
          name, value, expected: expectedChoices(WindowLayout.allCases.map(\.rawValue))
        ).stoppingMessage
      }
      return .layout(layout)
    case .split:
      guard let orientation = SplitOrientation(value) else {
        throw unknownValue(
          name, value, expected: expectedChoices(["horizontal", "vertical", "toggle"])
        ).stoppingMessage
      }
      return .split(orientation)
    }
  }

  /// An optional window selector, whose failure stops the message.
  private static func optionalSelector(_ token: Token) throws(CommandError) -> WindowSelector? {
    do {
      return try WindowSelector.optional(token)
    } catch {
      throw error.stoppingMessage
    }
  }
}
