import Testing

@testable import Yabai

//
// NOTE: The payload decoding of the window server connection notifications and the registration order of their types.
// The decoder only reads the buffer the test passes in; nothing here reaches the window server.
//

@Suite struct SLSNotificationTests {
  @Test func payloadIsNilWithoutBuffer() {
    #expect(SLSNotification.payload(nil, 8, as: UInt64.self) == nil)
    #expect(SLSNotification.payload(nil, 4, as: UInt32.self) == nil)
  }

  @Test func payloadIsNilWhenShorterThanType() {
    var bytes: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
    bytes.withUnsafeMutableBytes { buffer in
      #expect(SLSNotification.payload(buffer.baseAddress, 7, as: UInt64.self) == nil)
      #expect(SLSNotification.payload(buffer.baseAddress, 3, as: UInt32.self) == nil)
      #expect(SLSNotification.payload(buffer.baseAddress, 0, as: UInt32.self) == nil)
    }
  }

  @Test func payloadDecodesUInt64() {
    let expected: UInt64 = 0x0102_0304_0506_0708
    var bytes = withUnsafeBytes(of: expected) { Array($0) }
    let decoded = bytes.withUnsafeMutableBytes {
      SLSNotification.payload($0.baseAddress, $0.count, as: UInt64.self)
    }
    #expect(decoded == expected)
  }

  @Test func payloadDecodesUInt32FromLongerBuffer() {
    let expected: UInt32 = 0xDEAD_BEEF
    var bytes = withUnsafeBytes(of: expected) { Array($0) } + [0xAA, 0xBB, 0xCC, 0xDD]
    let decoded = bytes.withUnsafeMutableBytes {
      SLSNotification.payload($0.baseAddress, $0.count, as: UInt32.self)
    }
    #expect(decoded == expected)
  }

  @Test func payloadDecodesFromUnalignedAddress() {
    let expected: UInt32 = 0x1122_3344
    var bytes = [0xFF] + withUnsafeBytes(of: expected) { Array($0) }
    let decoded = bytes.withUnsafeMutableBytes { buffer in
      SLSNotification.payload(buffer.baseAddress! + 1, buffer.count - 1, as: UInt32.self)
    }
    #expect(decoded == expected)
  }

  @Test func registrationOrderMatchesDeclarationOrder() {
    #expect(
      SLSNotification.allCases.map(\.rawValue) == [
        1327, 1328, 808, 806, 807, 815, 816, 1202, 804, 1508,
      ])
  }

  @Test func unknownTypeHasNoCase() {
    #expect(SLSNotification(rawValue: 1) == nil)
  }
}
