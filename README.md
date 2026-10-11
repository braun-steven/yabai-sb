# Personal fork

This is my personal fork of yabai, where I (and AI) implement features and bug fixes that I need.

## Fork changes

- **`space_layout` config**: keeps a fixed number of spaces on each display, with one layout per display count, e.g. `yabai -m config space_layout 15 10:5 10:5:1b`. Spaces are moved, created, or destroyed (only empty ones) after display or space changes.
- **macOS 27**: releases after Tahoe take the Tahoe code paths (window notifications, window sub-level queries) instead of falling back to pre-Sequoia behavior.
- **`builtin_display_last` config**: orders the built-in display after all other displays, for both display and space indices.
- **`auto_padding` config**: removes padding on tiled spaces with at most one tiled window or tabbed container, globally or per space (`yabai -m config [--space <SPACE_SEL>] auto_padding on`). The configured padding is never changed, so `--grid` gives the same frame on every space.
- **Exclusive scratchpads**: `scratchpad_exclusive on` keeps at most one scratchpad shown, so toggling one hides the others. `scratchpad_raise on` focuses a covered scratchpad instead of hiding it, `scratchpad_below on` lets a focused tiled window cover a shown scratchpad instead of the scratchpad always floating above, and `scratchpad_grid <grid>` re-centers a scratchpad each time it is shown. Toggling a scratchpad on another space no longer makes macOS switch back to that space.
- **i3/sway container tree (`layout tree`)**: the only tiling layout; the bsp and stack layouts are removed and `layout` accepts `tree` (the default) or `float`. Windows live in an n-ary tree of `splith`, `splitv` and `tabbed` containers, like i3. New windows open next to the focused window in its container, empty containers close, and tabbed containers draw native tab bars with window titles that focus a tab on click, with an optional application icon left of the title (`tab_bar`, `tab_bar_height`, `tab_bar_offset` for the space between bar and windows, `tab_bar_font`, `tab_bar_icons`, `tab_bar_*_color`), nested tabs too. `tab_bar_style glass|i3` draws the bars in real Liquid Glass (`NSGlassEffectView`: a translucent track and a sliding pill for the active tab, tinted with the `tab_bar_*_color` colors; the default) or as flat i3 tabs; `tab_bar_backdrop glass|blur|off` draws a rounded glass or blur card behind the whole glass tabbed container with the bar on top and the window inset by `tab_bar_card_padding` below it, rounded concentric to the window corners (`tab_bar_window_radius`) and tinted with `tab_bar_backdrop_color`, so no wallpaper shows between bar and window; `tab_bar_font system:<size>` selects the system font; this replaces the stackline Hammerspoon plugin. i3 navigation: `window --focus north|east|south|west` walks the tree and restores the last focused child, `--focus parent|child` selects containers, `window --warp <dir>` is i3's `move` (swap, enter a container, leave at the edge, re-orient the space, cross displays), closing a window focuses the previous one in its container, `query --tree` prints the tree, and `query --windows` reports `split-type`/`stack-index` from it. Structure commands: `window --split horizontal|vertical|toggle`, `window --layout splith|splitv|tabbed|split|toggle|toggle-split`, `--insert`, `--stack`, `--resize`/`--ratio` (i3 percent shares), zoom, `space --balance|--rotate|--mirror`, and mouse drops on window edges. Configured with `tree_default_orientation`, `tree_workspace_layout`, `focus_wrapping` and `tree_autotiling` (each new window halves the focused one along its longer side, like the i3 autotiling script). The bsp-only selectors (`sibling`, `*_nephew`, `uncle`, `*_cousin`), the `split-child` window property and the options `split_ratio`, `split_type`, `window_placement`, `window_insertion_point`, `auto_balance` and `window_zoom_persist` are removed.

---

<!-- Please be careful editing the below HTML, as GitHub is quite finicky with anything that looks like an HTML tag in GitHub Flavored Markdown. -->
<p align="center">
  <img width="75%" src="assets/banner/banner.svg" alt="Banner">
</p>
<p align="center">
  <b>Tiling window management for the Mac.</b>
</p>
<p align="center">
  <a href="https://github.com/asmvik/yabai/blob/master/LICENSE.txt">
    <img src="https://img.shields.io/github/license/asmvik/yabai.svg?color=green" alt="License Badge">
  </a>
  <a href="https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc">
    <img src="https://img.shields.io/badge/view-documentation-green.svg" alt="Documentation Badge">
  </a>
  <a href="https://github.com/asmvik/yabai/wiki">
    <img src="https://img.shields.io/badge/view-wiki-green.svg" alt="Wiki Badge">
  </a>
  <a href="https://github.com/asmvik/yabai/blob/master/CHANGELOG.md">
    <img src="https://img.shields.io/badge/view-changelog-green.svg" alt="Changelog Badge">
  </a>
  <a href="https://github.com/asmvik/yabai/releases">
    <img src="https://img.shields.io/github/commits-since/asmvik/yabai/latest.svg?color=green" alt="Version Badge">
  </a>
</p>

## About

<img align="right" width="40%" src="assets/screenshot.png" alt="Screenshot">

yabai is a window management utility that is designed to work as an extension to the built-in window manager of macOS.
yabai allows you to control your windows, spaces and displays freely using an intuitive command line interface and optionally set user-defined keyboard shortcuts using [&nearr;&nbsp;skhd][gh-skhd] and other third-party software.

The primary function of yabai is tiling window management; automatically modifying your window layout using a binary space partitioning algorithm to allow you to focus on the content of your windows without distractions.
Additional features of yabai include focus-follows-mouse, disabling animations for switching spaces, creating spaces past the limit of 16 spaces, and much more.

## Installation and Configuration

- The [&nearr;&nbsp;yabai&nbsp;wiki][yabai-wiki] has both brief and detailed installation instructions for multiple installation methods, and also explains how to uninstall yabai completely.
- Sample configuration files can be found in the [&nearr;&nbsp;examples][yabai-examples] directory. Refer to the [&nearr;&nbsp;documentation][yabai-docs] or the wiki for further information.
- Keyboard shortcuts can be defined with [&nearr;&nbsp;skhd][gh-skhd] or any other suitable software you may prefer.

## Requirements and Caveats

Please read the below requirements carefully.
Make sure you fulfil all of them before filing an issue.

|Requirement|Note|
|-:|:-|
|Operating&nbsp;System&nbsp;Intel x86-64|Big Sur 11.0.0+, Monterey 12.0.0+, Ventura 13.0.0+, Sonoma 14.0.0+, Sequoia 15.0+, and Tahoe 26.0+ is supported.|
|Operating&nbsp;System&nbsp;Apple Silicon|Monterey 12.0.0+, Ventura 13.0.0+, Sonoma 14.0.0+, Sequoia 15.0+, and Tahoe 26.0+ is supported.|
|Accessibility&nbsp;API|yabai must be given permission to utilize the Accessibility API and will request access upon launch. The application must be restarted after access has been granted.|
|Screen Recording|yabai must be given Screen Recording permission if and only if you want to enable window animations, and will request access when necessary. The application must be restarted after access has been granted.|
|System&nbsp;Preferences&nbsp;(macOS 11.x, 12.x)|In the Mission Control pane, the setting "Displays have separate Spaces" must be enabled.|
|System&nbsp;Settings&nbsp;(macOS 13.x, 14.x, 15.x, 26.x)|In the Desktop & Dock tab, inside the Mission Control pane, the setting "Displays have separate Spaces" must be enabled.|

Please also take note of the following caveats.

|Caveat|Note|
|-:|:-|
|System&nbsp;Integrity&nbsp;Protection (Optional)|System Integrity Protection can be (partially) disabled for yabai to inject a scripting addition into Dock.app for controlling windows with functions that require elevated privileges. This enables control of the window server, which is the sole owner of all window connections, and enables additional features of yabai.|
|Code&nbsp;Signing|When building from source (or installing from HEAD), it is necessary to codesign the binary so it retains its accessibility and automation privileges when updated or rebuilt.|
|Finder&nbsp;Desktop|Some people disable the Finder Desktop window using an undocumented defaults write command. This breaks focusing of empty spaces and should be avoided when using yabai. To re-activate the Finder Desktop, run: "defaults write com.apple.finder CreateDesktop -bool true".|
|NSDocument-based&nbsp;Applications|Windows that utilize native macOS tabs such as Terminal and Finder, [do not behave correctly when creating tabs](https://github.com/asmvik/yabai/issues/68). Avoid creating tabs in these applications, consider alternatives that do not use NSDocument's tab system, or make these windows float using rules.|
|System&nbsp;Preferences&nbsp;(macOS 11.x, 12.x)|In the Mission Control pane, the setting "Automatically rearrange Spaces based on most recent use" should be disabled for commands that rely on the ordering of spaces to work reliably.|
|System&nbsp;Settings&nbsp;(macOS 13.x, 14.x, 15.x, 26.x)|In the Desktop & Dock tab, inside the Mission Control pane, the setting "Automatically rearrange Spaces based on most recent use" should be disabled for commands that rely on the ordering of spaces to work reliably.|
|System&nbsp;Settings&nbsp;(macOS 14.x, 15.x, 26.x)|In the Desktop & Dock tab, inside the Desktop & Stage Manager pane, the setting "Show Items On Desktop" should be enabled for display and space focus commands to work reliably in multi-display configurations.|
|System&nbsp;Settings&nbsp;(macOS 14.x, 15.x, 26.x)|In the Desktop & Dock tab, inside the Desktop & Stage Manager pane, the setting "Click wallpaper to reveal Desktop" should be set to "Only in Stage Manager" for display and space focus commands to work reliably.|

## License and Attribution

yabai is licensed under the [&nearr;&nbsp;MIT&nbsp;License][yabai-license], a short and simple permissive license with conditions only requiring preservation of copyright and license notices.
Licensed works, modifications, and larger works may be distributed under different terms and without source code.

Thanks to [@fools-mate][gh-fools-mate] for creating a logo and banner for this project and making them available for free.

Thanks to [@dominiklohmann][gh-dominiklohmann] for contributing great documentation, support, and more, for free.

## Disclaimer

Use at your own discretion.
I take no responsibility if anything should happen to your machine while trying to install, test or otherwise use this software in any form.
You acknowledge that you understand the potential risk that may come from disabling [&nearr;&nbsp;System&nbsp;Integrity&nbsp;Protection][external-about-sip] on your system, and I make no recommendation as to whether you should or should not disable System Integrity Protection.

<!-- Project internal links -->
[yabai-license]: LICENSE.txt
[yabai-examples]: https://github.com/asmvik/yabai/tree/master/examples
[yabai-wiki]: https://github.com/asmvik/yabai/wiki
[yabai-docs]: https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc

<!-- Links to other GitHub projects/users -->
[gh-skhd]: https://github.com/asmvik/skhd
[gh-fools-mate]: https://github.com/fools-mate
[gh-dominiklohmann]: https://github.com/dominiklohmann

<!-- External links -->
[external-about-sip]: https://support.apple.com/en-us/HT204899
