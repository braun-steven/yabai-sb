import ApplicationServices
import CPrivate
import Testing
import YabaiCore
import YabaiTestSupport

@testable import Yabai

extension DaemonState {
  @Suite
  @WM struct MouseHandlerTests {
    @Test("mouse_drop_action_regions")
    func mouseDropActionRegions() {
      let target = Window(id: 1)
      target.frame = CGRect(x: 100, y: 100, width: 200, height: 100)
      let ms = MouseState()
      Config.current.mouse.dropAction = .swap
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 150)) == .swap)
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 105)) == .warpTop)
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 295, y: 150)) == .warpRight)
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 195)) == .warpBottom)
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 105, y: 150)) == .warpLeft)
      // NOTE: mouse_drop_action stack makes the center a tab of the window instead
      Config.current.mouse.dropAction = .stack
      #expect(ms.resolveDrop(onto: target, at: CGPoint(x: 200, y: 150)) == .stack)
    }

    @Test func dropFeedbackClearsWhenTargetIsLostOrDragEnds() {
      let workspace = Workspace()
      let dragged = workspace.open(1, focus: true)
      let target = workspace.open(2)
      let ms = MouseState()
      ms.window = dragged
      ms.feedbackWindowID = target.id
      ms.feedbackDirection = .west

      ms.showDropFeedback(view: nil, window: nil, at: .zero)
      #expect(ms.feedbackWindowID == nil)
      #expect(ms.feedbackDirection == nil)
      #expect(ms.window === dragged)

      ms.feedbackWindowID = target.id
      ms.feedbackDirection = .east
      ms.clearWindow()
      #expect(ms.feedbackWindowID == nil)
      #expect(ms.feedbackDirection == nil)
      #expect(ms.window == nil)
    }

    // NOTE: a mouse down of the button that holds a drag means its mouse up was lost; another button does not.
    @Test func mouseDownOfTheDragButtonMeansALostMouseUp() {
      let ms = MouseState()
      let left = Int64(CGMouseButton.left.rawValue)
      let right = Int64(CGMouseButton.right.rawValue)
      #expect(!ms.isLostDrag(button: left))

      ms.window = Window(id: 0xFFFF_0001)
      ms.actionButton = left
      #expect(!ms.isLostDrag(button: left))

      ms.currentAction = .move
      #expect(ms.isLostDrag(button: left))
      #expect(!ms.isLostDrag(button: right))

      ms.window = nil
      #expect(!ms.isLostDrag(button: left))
    }
  }
}

@Suite struct MouseValueTests {
  static let dropDirections: [(MouseDropAction, InsertDirection?)] = [
    (.none, nil),
    (.stack, .stack),
    (.swap, .stack),
    (.warpTop, .north),
    (.warpRight, .east),
    (.warpBottom, .south),
    (.warpLeft, .west),
  ]

  @Test(arguments: dropDirections)
  func dropActionInsertsTowardItsSide(_ action: MouseDropAction, _ direction: InsertDirection?) {
    #expect(action.insertDirection == direction)
  }

  static let eventFlags: [(CGEventFlags, MouseModifiers)] = [
    ([], []),
    (.maskAlternate, .alt),
    (.maskShift, .shift),
    (.maskCommand, .cmd),
    (.maskControl, .ctrl),
    (.maskSecondaryFn, .fn),
    ([.maskAlternate, .maskShift], [.alt, .shift]),
    ([.maskCommand, .maskControl, .maskSecondaryFn], [.cmd, .ctrl, .fn]),
    // the other flags, and the device-dependent bits of a key, do not count
    ([.maskAlphaShift, .maskNumericPad, .maskHelp, .maskNonCoalesced], []),
    (CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08), .cmd),
  ]

  @Test(arguments: eventFlags)
  func modifiersOfEventFlags(_ flags: CGEventFlags, _ modifiers: MouseModifiers) {
    #expect(MouseModifiers(flags) == modifiers)
  }

  @Test func eachModifierKeyIsItsOwnModifier() {
    let modifiers = MouseModifierKey.allCases.map(\.modifiers)
    #expect(modifiers == [.alt, .shift, .cmd, .ctrl, .fn])
    #expect(modifiers.map(\.rawValue).reduce(0, |).nonzeroBitCount == modifiers.count)
  }

  // NOTE: a mouse down while a consumed click is pending means its mouse up was lost; the click is forgotten, and a
  // tab click only by a left mouse down.
  @Test(arguments: [
    (CGEventType.leftMouseDown, false),
    (CGEventType.rightMouseDown, true),
  ])
  func mouseDownForgetsALostClick(_ type: CGEventType, _ keepsTabClick: Bool) {
    let tap = MouseTapState()
    tap.consumeMouseClick = true
    tap.consumeTabClick = true
    tap.dragDetected = true
    tap.consumedEvent = CGEvent(source: nil)

    tap.forgetLostClick(before: type)

    #expect(!tap.consumeMouseClick)
    #expect(tap.consumedEvent == nil)
    #expect(!tap.dragDetected)
    #expect(tap.consumeTabClick == keepsTabClick)
  }
}
