import CoreGraphics
import Logging
import SortedCollections
import YabaiCore

//
// NOTE: The scroll animation of a scroll view (`scroll_animation_duration`). A flush of a scroll view moves most windows
// without resizing them: the strip scrolls, or columns shift when one opens, closes or moves. Those windows slide from
// where the window server has them to their placements instead of jumping. A frame of the slide moves each window
// through the scripting addition, about 0.2 ms each: the window server moves the window without asking its
// application, which an AX frame write per frame would take tens of milliseconds for. A window whose size changes is
// placed at once.
//
// The frames are `.scrollAnimationTick` events, posted with the key `.scrollAnimation` every `frameInterval`, so they
// stay in order with the other events; each frame computes its positions from the clock, so a late frame catches up
// instead of slowing the slide down. The last frame flushes the view again, which writes the placements through AX
// (the windows are there already, so the applications learn their frames) and draws the tab bars and borders.
//
// The flush after the last frame places the windows at once (`settling`): a window the payload did not move (it
// answers a move with a failure on macOS 27 whether or not the window moved) would otherwise slide again, forever.
// While a window slides, its moved events would see it off its tile and flush its view (`windowMoved`, `retile`), so
// they are ignored (`isSliding`). When the payload does not answer (no scripting addition), the windows are placed at
// once for `unavailableRetry`; in headless mode or with a duration of 0, always.
//

/// The windows of a view sliding to their placements.
struct ScrollAnimation {
  struct Slide {
    let window: WindowID
    let from: CGPoint
    let to: CGPoint
  }

  var slides: [Slide]
  var start: ContinuousClock.Instant
  var duration: Duration
}

@WM final class ScrollAnimator {
  static let shared = ScrollAnimator()

  /// The time between two frames of a slide: about 120 frames per second.
  static let frameInterval: Duration = .milliseconds(8)

  /// How long the windows are placed at once after the scripting addition did not answer a slide.
  static let unavailableRetry: Duration = .seconds(30)

  private var animations: [SpaceID: ScrollAnimation] = [:]

  /// The views whose last slide ended: their next flush places the windows at once, so a window that did not reach its
  /// placement (the payload moved it nowhere) is placed through AX instead of sliding again.
  private var settling: Set<SpaceID> = []

  /// Until when the windows are placed at once because the scripting addition did not answer.
  private var unavailableUntil: ContinuousClock.Instant?

  // NOTE: The window server and the payload, replaced in tests, where headless mode would place every window at once.

  /// Where the window server has a window now.
  var currentBounds: @WM (WindowID) -> CGRect? = { SLS.windowBounds(SLS.connection, $0) }
  /// Moves a window for a frame; false when the payload did not answer.
  var slide: @WM (WindowID, Int32, Int32) -> Bool = {
    ScriptingAddition.shared.slideWindow($0, x: $1, y: $2)
  }
  /// Whether views animate in headless mode.
  var animatesInHeadlessMode = false

  /// Whether the window slides in an animation now; its moved events are ignored meanwhile.
  func isSliding(_ windowID: WindowID) -> Bool {
    animations.values.contains { animation in
      animation.slides.contains { $0.window == windowID }
    }
  }

  /// Whether the view has a slide running.
  func isAnimating(_ sid: SpaceID) -> Bool { animations[sid] != nil }

  /// Ends the slide of a view without placing its windows: its layout changed, or the view went away.
  func cancel(_ sid: SpaceID) {
    animations[sid] = nil
    settling.remove(sid)
  }

  /// Forgets every slide and the state of the scripting addition, and uses the window server and the payload again
  /// (tests).
  func reset() {
    animations = [:]
    settling = []
    unavailableUntil = nil
    currentBounds = { SLS.windowBounds(SLS.connection, $0) }
    slide = { ScriptingAddition.shared.slideWindow($0, x: $1, y: $2) }
    animatesInHeadlessMode = false
  }

  /// Starts sliding the windows of the view that move without being resized, from where the window server has them to
  /// their placements, and returns the placements to make at once: the others, or all of them when the view does not
  /// animate. A slide that was running for the view is replaced, starting from where its windows are now.
  func animate(_ view: View, _ placements: [WindowPlacement]) -> [WindowPlacement] {
    let milliseconds = Config.current.space.scrollAnimationDuration
    animations[view.sid] = nil
    if settling.remove(view.sid) != nil { return placements }
    if let unavailableUntil, ContinuousClock.now < unavailableUntil { return placements }
    guard milliseconds > 0, view.layout == .scroll,
      !Headless.isEnabled || animatesInHeadlessMode
    else { return placements }

    var slides: [ScrollAnimation.Slide] = []
    var immediate: [WindowPlacement] = []
    for placement in placements {
      let target = CGRect(
        x: CGFloat(placement.x), y: CGFloat(placement.y), width: CGFloat(placement.w),
        height: CGFloat(placement.h))
      let bounds = currentBounds(placement.window.id)
      guard let bounds, ScrollEasing.slides(from: bounds, to: target) else {
        immediate.append(placement)
        continue
      }
      slides.append(
        ScrollAnimation.Slide(window: placement.window.id, from: bounds.origin, to: target.origin))
    }
    if slides.isEmpty { return placements }

    animations[view.sid] = ScrollAnimation(
      slides: slides, start: .now, duration: .milliseconds(milliseconds))
    EventLoop.post(.scrollAnimationTick, after: .zero, key: .scrollAnimation)
    return immediate
  }

  //
  // NOTE: A window can leave the strip while it slides (another space or display, floating, destroyed), and the view
  // can stop being a scroll view. Such a slide is dropped, so the window is not dragged back to its old place.
  //

  /// Moves the windows of every running slide to where they are now, and ends the slides that are done by flushing
  /// their views, which places their windows at once.
  func tick() {
    let now = ContinuousClock.now
    var finished: [SpaceID] = []
    let wm = WindowManager.shared

    for (sid, animation) in animations {
      guard let view = SpaceManager.shared.views[sid], view.layout == .scroll else {
        animations[sid] = nil
        continue
      }
      let slides = animation.slides.filter { wm.managedWindows[$0.window] === view }

      let progress = ScrollEasing.progress(
        elapsed: (now - animation.start) / .milliseconds(1),
        duration: animation.duration / .milliseconds(1))

      var reachable = true
      for slide in slides where reachable {
        let x = ScrollEasing.position(
          from: Float(slide.from.x), to: Float(slide.to.x), progress: progress)
        let y = ScrollEasing.position(
          from: Float(slide.from.y), to: Float(slide.to.y), progress: progress)
        reachable = self.slide(slide.window, Int32(x), Int32(y))
      }

      if !reachable {
        Logger.windows.debug("scroll: the scripting addition did not answer; placing at once")
        unavailableUntil = now + Self.unavailableRetry
      }
      if progress >= 1 || !reachable || slides.isEmpty {
        finished.append(sid)
      } else if slides.count != animation.slides.count {
        animations[sid]?.slides = slides
      }
    }

    for sid in finished {
      animations[sid] = nil
      guard let view = SpaceManager.shared.views[sid] else { continue }
      settling.insert(sid)
      view.flush()
      settling.remove(sid)
    }
    if !animations.isEmpty {
      EventLoop.post(.scrollAnimationTick, after: Self.frameInterval, key: .scrollAnimation)
    }
  }
}
