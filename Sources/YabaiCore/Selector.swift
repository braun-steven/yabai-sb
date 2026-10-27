//
// NOTE: The selectors of displays, spaces and windows, parsed from one token without looking anything up. `resolve`
// looks the selected display, space or window up through a SelectorContext when the command runs, and throws the
// failure of one it cannot find. A relative selector (a direction, prev, next or a stack position) needs the acting
// display, space or window.
//

/// Throws "could not locate <what>." when the lookup found nothing.
private func located<Value>(_ value: Value?, _ what: String) throws(CommandError) -> Value {
  guard let value else { throw CommandError("could not locate \(what).\n") }
  return value
}

/// A display selector (`DISPLAY_SEL` in the manual).
public enum DisplaySelector: Equatable, Sendable {
  case arrangement(Int)
  case direction(Direction)
  case prev
  case next
  case first
  case last
  case recent
  case mouse
  /// Any other word: a display label, which `resolve` looks up.
  case label(Token)

  /// nil when the token is no display selector.
  public init?(_ token: Token) {
    switch token.value {
    case .int(let index):
      self = .arrangement(index)
    case .string:
      if let direction = parseDirection(token) {
        self = .direction(direction)
      } else if token.equals(Argument.prev) {
        self = .prev
      } else if token.equals(Argument.next) {
        self = .next
      } else if token.equals(Argument.first) {
        self = .first
      } else if token.equals(Argument.last) {
        self = .last
      } else if token.equals(Argument.recent) {
        self = .recent
      } else if token.equals(Argument.mouse) {
        self = .mouse
      } else {
        self = .label(token)
      }
    default:
      return nil
    }
  }

  /// The failure of a token that selects no display.
  public static func invalid(_ token: Token) -> CommandError {
    CommandError("value '\(token)' is not a valid option for DISPLAY_SEL\n")
  }

  /// The selector of a command that needs one; throws the failure of a token that is none.
  public static func required(_ token: Token) throws(CommandError) -> DisplaySelector {
    guard let selector = DisplaySelector(token) else { throw invalid(token) }
    return selector
  }

  /// The selected display, relative to acting. nil only for 'recent' without a recent display.
  public func resolve<C: SelectorContext>(acting: DisplayID?, _ context: C) throws(CommandError)
    -> DisplayID?
  {
    switch self {
    case .arrangement(let index):
      guard let did = context.display(.arrangement(index)) else {
        throw CommandError("could not locate display with arrangement index '\(index)'.\n")
      }
      return did
    case .direction(let direction):
      guard let acting else { throw CommandError("could not locate the selected display.\n") }
      return try located(
        context.display(.inDirection(direction, from: acting)),
        "\(directionDescription(direction)) display")
    case .prev:
      guard let acting else { throw CommandError("could not locate the selected display.\n") }
      return try located(context.display(.prev(acting)), "the previous display")
    case .next:
      guard let acting else { throw CommandError("could not locate the selected display.\n") }
      return try located(context.display(.next(acting)), "the next display")
    case .first:
      return try located(context.display(.first), "the first display")
    case .last:
      return try located(context.display(.last), "the last display")
    case .recent:
      return context.display(.recent)
    case .mouse:
      return try located(context.display(.cursor), "display containing cursor")
    case .label(let label):
      guard let did = context.displayLabel(label) else { throw DisplaySelector.invalid(label) }
      return did
    }
  }

  // NOTE: `window <WINDOW_SEL> --display` measures a direction, 'prev' and 'next' from the display of the window it
  // sends, like sway's `move container to output <dir>` (`cmd_move_container` in sway/commands/move.c takes the
  // reference output from the container's own workspace). The window that a message acts on without a selector (the
  // focused or pending focus window) keeps the active display, so the focused form is unchanged, also when focus is on
  // an empty display. 'recent' and the absolute selectors need no origin. `window --space` measures 'prev' and 'next'
  // from the active space instead, as sway's `move container to workspace next|prev` does (`workspace_by_name` in
  // sway/tree/workspace.c starts from the focused workspace). `space <SPACE_SEL> --display`, --create and --pin use
  // the same rule with the selected space and its display, like sway's `move workspace to output <dir>`.

  /// The display that `window --display` (or `space --display`) resolves a relative selector from: the active display
  /// for the window (space) acted on without a selector, else the display of the window (space), or the active display
  /// when it is on none. `windowDisplay` is read only for a selected window (space).
  public static func placementOrigin<ID>(
    selected: Bool, windowDisplay: () -> ID?, active: () -> ID?
  ) -> ID? {
    guard selected, let did = windowDisplay() else { return active() }
    return did
  }
}

/// A space selector (`SPACE_SEL` in the manual).
public enum SpaceSelector: Equatable, Sendable {
  case missionControl(Int)
  case prev
  case next
  case first
  case last
  case recent
  case mouse
  /// Any other word: a space label, which `resolve` looks up.
  case label(Token)

  /// nil when the token is no space selector.
  public init?(_ token: Token) {
    switch token.value {
    case .int(let index):
      self = .missionControl(index)
    case .string:
      if token.equals(Argument.prev) {
        self = .prev
      } else if token.equals(Argument.next) {
        self = .next
      } else if token.equals(Argument.first) {
        self = .first
      } else if token.equals(Argument.last) {
        self = .last
      } else if token.equals(Argument.recent) {
        self = .recent
      } else if token.equals(Argument.mouse) {
        self = .mouse
      } else {
        self = .label(token)
      }
    default:
      return nil
    }
  }

  /// The failure of a token that selects no space.
  public static func invalid(_ token: Token) -> CommandError {
    CommandError("value '\(token)' is not a valid option for SPACE_SEL\n")
  }

  /// The selector of a command that needs one; throws the failure of a token that is none.
  public static func required(_ token: Token) throws(CommandError) -> SpaceSelector {
    guard let selector = SpaceSelector(token) else { throw invalid(token) }
    return selector
  }

  /// The selected space, relative to acting. nil only for 'recent' without a recent space.
  public func resolve<C: SelectorContext>(acting: SpaceID?, _ context: C) throws(CommandError)
    -> SpaceID?
  {
    switch self {
    case .missionControl(let index):
      guard let sid = context.space(.missionControl(index)) else {
        throw CommandError("could not locate space with mission-control index '\(index)'.\n")
      }
      return sid
    case .prev:
      guard let acting else { throw CommandError("could not locate the selected space.\n") }
      return try located(context.space(.prev(acting)), "the previous space")
    case .next:
      guard let acting else { throw CommandError("could not locate the selected space.\n") }
      return try located(context.space(.next(acting)), "the next space")
    case .first:
      return try located(context.space(.first), "the first space")
    case .last:
      return try located(context.space(.last), "the last space")
    case .recent:
      return context.space(.recent)
    case .mouse:
      return try located(context.space(.cursor), "space containing cursor")
    case .label(let label):
      guard let sid = context.spaceLabel(label) else { throw SpaceSelector.invalid(label) }
      return sid
    }
  }

  // NOTE: `space_auto_back_and_forth` is sway's `workspace_auto_back_and_forth` (`workspace_auto_back_and_forth` in
  // sway/tree/workspace.c): sway applies it to `workspace <name>` and `workspace number <n>` only, not to
  // next/prev, so here it applies to an index and a label only. Without a recent space, or when the recent space is the
  // selected one, the selected space stays and its focus fails as already focused.

  /// The space `space --focus` focuses for the selected space `target`: the recent space when back-and-forth is on, the
  /// selector is an index or a label, and `target` is the focused space; else `target`. `focused` is read only then.
  public func focusTarget<ID: Equatable>(
    _ target: ID, autoBackAndForth: Bool, focused: @autoclosure () -> ID?, recent: ID?
  ) -> ID {
    switch self {
    case .missionControl, .label:
      guard autoBackAndForth, let recent, recent != target, focused() == target else {
        return target
      }
      return recent
    case .prev, .next, .first, .last, .recent, .mouse:
      return target
    }
  }
}

/// A window of the stack (tabbed container) of the acting window: `stack.<value>`.
public enum StackSelector: Equatable, Sendable {
  case prev
  case next
  case first
  case last
  case recent
  /// From 1.
  case position(Int)

  /// token is the part after "stack."; nil when it selects no stacked window.
  public init?(_ token: Token) {
    if token.equals(Argument.prev) {
      self = .prev
    } else if token.equals(Argument.next) {
      self = .next
    } else if token.equals(Argument.first) {
      self = .first
    } else if token.equals(Argument.last) {
      self = .last
    } else if token.equals(Argument.recent) {
      self = .recent
    } else if token.isValid, let index = token.positiveInteger, index > 0 {
      self = .position(index)
    } else {
      return nil
    }
  }
}

/// A window selector (`WINDOW_SEL` in the manual).
public enum WindowSelector: Equatable, Sendable {
  case id(WindowID)
  case direction(Direction)
  case mouse
  case largest
  case smallest
  case prev
  case next
  case first
  case last
  case recent
  case stack(StackSelector)
  /// Any other word that is a valid window label: `resolve` looks the window up by its label.
  case label(Token)

  /// nil when the token is no window selector.
  public init?(_ token: Token) {
    // NOTE: a window id is read as a uint32_t: ids beyond Int32.max are no integer token.
    if let id = token.unsignedInteger {
      self = .id(WindowID(id))
      return
    }

    switch token.value {
    case .string:
      if let direction = parseDirection(token) {
        self = .direction(direction)
      } else if token.equals(Argument.mouse) {
        self = .mouse
      } else if token.equals(Argument.largest) {
        self = .largest
      } else if token.equals(Argument.smallest) {
        self = .smallest
      } else if token.equals(Argument.prev) {
        self = .prev
      } else if token.equals(Argument.next) {
        self = .next
      } else if token.equals(Argument.first) {
        self = .first
      } else if token.equals(Argument.last) {
        self = .last
      } else if token.equals(Argument.recent) {
        self = .recent
      } else if token.hasPrefix(Argument.stackPrefix),
        let stack = StackSelector(token.dropFirst(Argument.stackPrefix.count))
      {
        self = .stack(stack)
      } else if !LabelKind.windowLabel.isReserved(token) {
        self = .label(token)
      } else {
        return nil
      }
    default:
      return nil
    }
  }

  /// The failure of a token that selects no window.
  public static func invalid(_ token: Token) -> CommandError {
    CommandError("value '\(token)' is not a valid option for WINDOW_SEL\n")
  }

  /// The selector of a command that needs one; throws the failure of a token that is none.
  public static func required(_ token: Token) throws(CommandError) -> WindowSelector {
    guard let selector = WindowSelector(token) else { throw invalid(token) }
    return selector
  }

  /// The selector of a command that may have one: nil for a missing token; throws the failure of a given token that
  /// is none.
  public static func optional(_ token: Token) throws(CommandError) -> WindowSelector? {
    guard token.isValid else { return nil }
    return try required(token)
  }

  /// The selected window, relative to acting. Every window selector fails when it finds nothing, 'recent' too.
  public func resolve<C: SelectorContext>(acting: C.Window?, _ context: C) throws(CommandError)
    -> C.Window
  {
    switch self {
    case .id(let id):
      guard let window = context.window(.id(id)) else {
        throw CommandError(
          "could not locate window with the specified id '\(Int(Int32(bitPattern: id.rawValue)))'.\n"
        )
      }
      return window
    case .label(let label):
      guard let window = context.windowLabel(label) else {
        throw CommandError("could not locate window with label '\(label.string)'.\n")
      }
      return window
    case .direction(let direction):
      guard let acting else { throw CommandError("could not locate the selected window.\n") }
      return try located(
        context.window(.inDirection(direction, from: acting)),
        "\(directionDescription(direction)) managed window")
    case .mouse:
      return try located(context.window(.belowCursor), "a window below the cursor")
    case .largest:
      return try located(context.window(.largest), "window with the largest area")
    case .smallest:
      return try located(context.window(.smallest), "window with the smallest area")
    case .prev:
      guard let acting else { throw CommandError("could not locate the selected window.\n") }
      return try located(context.window(.prev(acting)), "the prev managed window")
    case .next:
      guard let acting else { throw CommandError("could not locate the selected window.\n") }
      return try located(context.window(.next(acting)), "the next managed window")
    case .first:
      return try located(context.window(.first), "the first managed window")
    case .last:
      return try located(context.window(.last), "the last managed window")
    case .recent:
      return try located(context.window(.recent), "the most recently focused window")
    case .stack(let stack):
      guard let acting else { throw CommandError("could not locate the selected window.\n") }
      switch stack {
      case .prev: return try located(context.window(.stackPrev(acting)), "the prev stacked window")
      case .next: return try located(context.window(.stackNext(acting)), "the next stacked window")
      case .first:
        return try located(context.window(.stackFirst(acting)), "the first stacked window")
      case .last: return try located(context.window(.stackLast(acting)), "the last stacked window")
      case .recent:
        return try located(context.window(.stackRecent(acting)), "the recent stacked window")
      case .position(let index):
        guard let window = context.window(.stackPosition(acting, index)) else {
          throw CommandError("could not locate the stacked window in position \(index).\n")
        }
        return window
      }
    }
  }
}
