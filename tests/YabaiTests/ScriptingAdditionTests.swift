import CPrivate
import OSAX
import Testing
import YabaiTestSupport

@testable import Yabai

@Test func scriptingAdditionEmbeddedVersionMatchesBothBinaries() throws {
  let version = Array(String(cString: sa_payload_version()).utf8) + [0]
  for (base, count) in [
    (sa_payload_bytes(), sa_payload_size()), (sa_loader_bytes(), sa_loader_size()),
  ] {
    let bytes = UnsafeBufferPointer(start: try #require(base), count: Int(count))
    #expect(bytes.count >= version.count)
    #expect(
      (0...(bytes.count - version.count)).contains { offset in
        bytes[offset..<(offset + version.count)].elementsEqual(version)
      })
  }
}

@Test func scriptingAdditionPayloadWireLayout() {
  var payload = SAPayload()
  payload.pack(UInt64(0x0102_0304_0506_0708))
  payload.pack(UInt64(9))
  payload.pack(UInt64(0))
  payload.pack(true)
  #expect(
    payload.message(SA_OPCODE_SPACE_MOVE) == [
      26, 0, 5, 8, 7, 6, 5, 4, 3, 2, 1, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ])

  var layer = SAPayload()
  layer.pack(UInt32(0x0102_0304))
  layer.pack(Int32(-2))
  #expect(layer.message(SA_OPCODE_WINDOW_LAYER) == [9, 0, 9, 4, 3, 2, 1, 254, 255, 255, 255])

  var opacity = SAPayload()
  opacity.pack(UInt32(0x0102_0304))
  opacity.pack(Float(0.5))
  opacity.pack(Float(1.25))
  #expect(
    opacity.message(SA_OPCODE_WINDOW_OPACITY_FADE) == [
      13, 0, 8, 4, 3, 2, 1, 0, 0, 0, 63, 0, 0, 160, 63,
    ])

  var sticky = SAPayload()
  sticky.pack(UInt32(0x0102_0304))
  sticky.pack(false)
  #expect(sticky.message(SA_OPCODE_WINDOW_STICKY) == [6, 0, 10, 4, 3, 2, 1, 0])
}

@Test func scriptingAdditionPayloadOverflow() {
  var payload = SAPayload()
  for _ in 0..<(Int(SA_SOCKET_BUFF_LEN) - 3) { payload.pack(UInt8(0)) }
  #expect(payload.message(SA_OPCODE_WINDOW_ORDER_IN)?.count == Int(SA_SOCKET_BUFF_LEN))
  payload.pack(UInt8(1))
  #expect(payload.message(SA_OPCODE_WINDOW_ORDER_IN) == nil)
}
