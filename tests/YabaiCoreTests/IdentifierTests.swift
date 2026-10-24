import Testing

@testable import YabaiCore

@Suite struct IdentifierTests {
  @Test func windowIDRejectsZero() {
    #expect(WindowID(nonzero: 0) == nil)
  }

  @Test func windowIDPreservesValuesOrdersAndDescribesAsDecimal() throws {
    let lower = try #require(WindowID(nonzero: 0xFFFF_0001))
    let upper = try #require(WindowID(nonzero: UInt32.max))

    #expect(lower.rawValue == 0xFFFF_0001)
    #expect(upper.rawValue == UInt32.max)
    #expect(lower < upper)
    #expect(upper.description == "4294967295")
  }

  @Test func spaceIDRejectsZero() {
    #expect(SpaceID(nonzero: 0) == nil)
  }

  @Test func spaceIDPreservesValuesOrdersAndDescribesAsDecimal() throws {
    let lower = try #require(SpaceID(nonzero: 0x1_0000_0000))
    let upper = try #require(SpaceID(nonzero: UInt64.max))

    #expect(lower.rawValue == 0x1_0000_0000)
    #expect(upper.rawValue == UInt64.max)
    #expect(lower < upper)
    #expect(upper.description == "18446744073709551615")
  }

  @Test func displayIDRejectsZero() {
    #expect(DisplayID(nonzero: 0) == nil)
  }

  @Test func displayIDPreservesValuesOrdersAndDescribesAsDecimal() throws {
    let lower = try #require(DisplayID(nonzero: 0x8000_0001))
    let upper = try #require(DisplayID(nonzero: UInt32.max))

    #expect(lower.rawValue == 0x8000_0001)
    #expect(upper.rawValue == UInt32.max)
    #expect(lower < upper)
    #expect(upper.description == "4294967295")
  }
}
