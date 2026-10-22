import ApplicationServices
import Darwin
import Testing

@testable import Yabai

//
// NOTE: The checked casts of `Sources/Yabai/Platform/AX.swift` and the public pid of an AX element. None of them reaches
// the window server: the application element is local to this process.
//

@Suite struct AXAttributeTests {
  @Test func castAcceptsMatchingCFType() {
    let title = "AXTitle" as CFString
    let cast: CFString? = castAttribute(title, typeID: CFStringGetTypeID())
    #expect(cast != nil)
  }

  @Test func castRefusesCFNumberWhereStringIsExpected() {
    let number = withUnsafePointer(to: Int32(7)) { CFNumberCreate(nil, .sInt32Type, $0) }!
    let cast: CFString? = castAttribute(number, typeID: CFStringGetTypeID())
    #expect(cast == nil)
  }

  @Test func castReturnsTheNumberWhenItsTypeMatches() {
    let number = withUnsafePointer(to: Int32(7)) { CFNumberCreate(nil, .sInt32Type, $0) }!
    let cast: CFNumber? = castAttribute(number, typeID: CFNumberGetTypeID())
    #expect(cast != nil)
  }

  @Test func pidOfApplicationElementIsTheProcessPid() {
    #expect(AXUIElement.application(getpid()).pid == getpid())
  }
}
