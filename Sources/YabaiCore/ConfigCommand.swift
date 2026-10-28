/// Names and scope for commands in the config domain.
public enum ConfigCommand {
  public enum Name: String, CaseIterable, Equatable, Sendable {
    case debugOutput = "debug_output"
    case mouseFollowsFocus = "mouse_follows_focus"
    case focusFollowsMouse = "focus_follows_mouse"
    case displayArrangementOrder = "display_arrangement_order"
    case builtinDisplayLast = "builtin_display_last"
    case windowOriginDisplay = "window_origin_display"
    case windowShadow = "window_shadow"
    case insertFeedbackColor = "insert_feedback_color"
    case windowBorder = "window_border"
    case windowBorderWidth = "window_border_width"
    case windowBorderHideSingle = "window_border_hide_single"
    case activeWindowBorderColor = "active_window_border_color"
    case normalWindowBorderColor = "normal_window_border_color"
    case tabBar = "tab_bar"
    case tabBarHeight = "tab_bar_height"
    case tabBarOffset = "tab_bar_offset"
    case tabBarFont = "tab_bar_font"
    case tabBarIcons = "tab_bar_icons"
    case tabBarStyle = "tab_bar_style"
    case tabBarAppearance = "tab_bar_appearance"
    case tabBarBackdrop = "tab_bar_backdrop"
    case tabBarCardPadding = "tab_bar_card_padding"
    case tabBarWindowRadius = "tab_bar_window_radius"
    case tabBarFocusedColor = "tab_bar_focused_color"
    case tabBarFocusedTextColor = "tab_bar_focused_text_color"
    case tabBarInactiveColor = "tab_bar_inactive_color"
    case tabBarInactiveTextColor = "tab_bar_inactive_text_color"
    case tabBarUnfocusedColor = "tab_bar_unfocused_color"
    case tabBarUnfocusedTextColor = "tab_bar_unfocused_text_color"
    case tabBarBackdropColor = "tab_bar_backdrop_color"
    case topPadding = "top_padding"
    case bottomPadding = "bottom_padding"
    case leftPadding = "left_padding"
    case rightPadding = "right_padding"
    case layout
    case windowGap = "window_gap"
    case autoPadding = "auto_padding"
    case treeDefaultOrientation = "tree_default_orientation"
    case treeWorkspaceLayout = "tree_workspace_layout"
    case treeAutotiling = "tree_autotiling"
    case focusWrapping = "focus_wrapping"
    case spaceAutoBackAndForth = "space_auto_back_and_forth"
    case mouseModifier = "mouse_modifier"
    case mouseAction1 = "mouse_action1"
    case mouseAction2 = "mouse_action2"
    case mouseDropAction = "mouse_drop_action"
    case mouseDropPreview = "mouse_drop_preview"
    case mouseDragSplit = "mouse_drag_split"
    case externalBar = "external_bar"
    case skipWindowFocusAnimation = "skip_window_focus_animation"
    case spaceLayout = "space_layout"
    case scratchpadExclusive = "scratchpad_exclusive"
    case scratchpadRaise = "scratchpad_raise"
    case scratchpadBelow = "scratchpad_below"
    case scratchpadGrid = "scratchpad_grid"
  }

  /// Parses the optional scope prefix, leaving the command token intact for byte-accurate failures.
  public static func parseScope(_ first: Token, _ message: inout some TokenSource)
    throws(CommandError) -> (SpaceSelector?, Token)
  {
    guard first.equals("--space") else { return (nil, first) }
    return (try SpaceSelector.required(message.next()), message.next())
  }

  /// Parses one command name and preserves the original token in an unknown-command error.
  public static func parseName(_ token: Token) throws(CommandError) -> Name {
    guard let name = Name(token: token) else {
      throw CommandError.unknownCommand(Token(Domain.config), token)
    }
    return name
  }
}
