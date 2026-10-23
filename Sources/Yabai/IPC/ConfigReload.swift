import Foundation
import Synchronization
import YabaiCore

//
// NOTE: `config --reload [<file>]` reads the yabai.toml that `config --check` reads (the daemon's file, or the file given)
// and checks it. A failure is the failure response, and nothing changes. Otherwise the handler reconciles the document with
// the running state for each ConfigStep, in order, with nothing between the steps (ConfigLoader.reconcile): only the
// settings whose value differs are run, so the layouts, the windows and the spaces stay as they are. Overrides made by
// `config`, `rule --add` or `signal --add` since the last load are put back by the same reconcile. Rules apply to windows
// created later, as before. The reply is `reloaded <file>: <n> changes`.
//
// `config --overrides` lists what differs from the last applied document (configOverrideLines).
//

/// Writes `config --reload [<file>]`: `reloaded <file>: <n> changes`, or the failures of the check, which change nothing.
@WM func handleConfigReload(_ rsp: inout Response, _ message: inout Message) throws(CommandError) {
  let (path, check) = try checkConfigFile("--reload", &message)
  guard let document = check.document, check.report.failures == 0 else {
    rsp.fail(CommandError(ResponseText(stringLiteral: check.report.text)))
    return
  }

  var result = ConfigReconcileResult()
  for step in ConfigStep.allCases {
    result += ConfigLoader.shared.reconcile(to: document, step: step)
  }
  rsp.write("reloaded \(path): \(result.changes) changes\n")
}

/// Writes `config --overrides`: the lines of configOverrideLines, or nothing when no value is overridden.
@WM func handleConfigOverrides(_ rsp: inout Response, _ message: inout Message) throws(CommandError)
{
  try noConfigArgument("--overrides", &message)
  for line in configOverrideLines() {
    rsp.write(ResponseText(stringLiteral: line + "\n"))
  }
}

//
// NOTE: Reset inventory of resetConfigToStartupDefaults, which the yabairc reload used. C3.3 no longer calls it; C5.1
// deletes it. A setting of the config domain is one of three kinds.
//
// - In Config only, reset by Config.resetToDefaults (which applies the space defaults too): every window, tab bar,
//   border, opacity, shadow, mouse, animation, scratchpad, window and display option, and the global space options
//   (layout, gaps, padding, auto_padding, tree_*, skip_window_focus_animation, space_layout). Observers follow the groups
//   that changed (ConfigObserver).
// - Config plus a window server or manager effect, restored here only when the value differed from the default, with the
//   effect of the option's own setter: focus_follows_mouse (the event tap), mouse_modifier (the tap's modifier),
//   mouse_drag_split (the tap's copy of the option),
//   display_arrangement_order and builtin_display_last (the space caches), external_bar (the spaces are marked invalid),
//   scratchpad_below (the scratchpad layers), tab_bar_font (the font of the bars is back to the default, nil as at startup).
// - Not in Config: debug_output (Log.verbose), restored to the value the daemon started with.
//
// Not reset, by design: the values of spaces and their views. A value set with `--space`, and the layout, gaps, padding and
// auto_padding that a space already has, stay as they are; a global space option changes only the defaults of the spaces
// that are created later. Space layouts (space_layout) are cleared without re-laying out the spaces.
//

/// Restores the config of a new daemon: `Config.resetToDefaults`, then the effect of each setting that the daemon keeps
/// outside Config and that changed. Nothing is scheduled: the caller runs the config file afterwards, which re-applies the
/// settings it sets.
@WM func resetConfigToStartupDefaults() {
  let config = Config.current
  let defaults = Config()

  let focusFollowsMouse = config.window.focusFollowsMouse != defaults.window.focusFollowsMouse
  let mouseModifier = config.mouse.modifier != defaults.mouse.modifier
  let mouseDragSplit = config.mouse.dragSplit != defaults.mouse.dragSplit
  let displayOrder =
    config.display.order != defaults.display.order
    || config.display.builtinDisplayLast != defaults.display.builtinDisplayLast
  let externalBar = config.display.externalBar != defaults.display.externalBar
  let scratchpadBelow = config.scratchpad.below != defaults.scratchpad.below
  let tabBarFont = config.tabBar.fontName != defaults.tabBar.fontName

  config.resetToDefaults()

  if focusFollowsMouse {
    WindowManager.shared.setFocusFollowsMouse(defaults.window.focusFollowsMouse)
  }
  if mouseModifier {
    MouseState.shared.tap.modifier = defaults.mouse.modifier
  }
  if mouseDragSplit {
    MouseState.shared.tap.dragSplit.store(defaults.mouse.dragSplit, ordering: .relaxed)
  }
  if displayOrder {
    DisplayManager.shared.invalidateSpaceCaches()
  }
  if externalBar {
    SpaceManager.shared.markSpacesInvalid()
  }
  if scratchpadBelow {
    WindowManager.shared.setScratchpadLayers()
  }
  if tabBarFont {
    // NOTE: The startup value is nil (only tab_bar_font sets the font), so the bars use the same fallback as at startup.
    WindowManager.shared.tabBarFont = nil
  }

  Log.verbose.store(Log.verboseAtStartup.load(ordering: .relaxed), ordering: .relaxed)
}
