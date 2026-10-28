import Darwin
import Dispatch
import Fixtures
import LoaderFixture
import OSAXCoreAPI
import RecordingAdapter
import SwiftPayloadCore
import Testing

@Suite(.serialized) struct PayloadTests {
  @Test func loaderCompletionFailureAndCleanup() {
    // 0 ready; 1 pthread failure; 2 never completes; 3 dlopen failure; 4 worker not exited;
    // 5 bootstrap has not returned from pthread creation; 6 allocation failure; 7 bad readiness;
    // 8 bootstrap termination failure; 9 state conversion failure.
    for mode: Int32 in 0...9 {
      sa_loader_test_mode(mode)
      #expect(sa_loader_main() == (mode == 0 ? 0 : 1))
      let expected = [3, 3, 0, 3, 0, 0, 1, 3, 0, 3][Int(mode)]
      #expect(sa_loader_test_deallocations() == expected)
      if mode == 5 { #expect(sa_loader_test_terminations() == 1) }
    }
  }

  @Test func allOpcodesAndTruncations() {
    let core = Core()
    for message in fixtures() {
      #expect(core.valid(message))
      for count in 0..<message.count { #expect(!core.valid(Array(message.prefix(count)))) }
      #expect(!core.valid(message + [0]))
    }
    #expect(!core.valid([0]))
    #expect(!core.valid([255]))
    for opcode: UInt8 in [17, 20] {
      #expect(!core.valid([opcode] + packed(Int32(-1))))
      #expect(!core.valid([opcode] + packed(Int32.max)))
      #expect(core.valid([opcode] + packed(Int32(0))))
    }
    #expect(!core.valid([18] + packed(UInt64(1)) + packed(Int32(-1))))
    for opcode: UInt8 in [7, 8, 14, 15] {
      #expect(!core.valid([opcode] + packed(UInt32(7)) + packed(Float(0.5)) + packed(Float(1))))
    }
    #expect(!core.valid([10] + packed(UInt32(7)) + [2]))
    #expect(!core.valid([12] + packed(UInt32(7))))
  }

  // Every fixed-size opcode: lengths 0 to expected-1 are rejected, and so is one byte too many.
  @Test(arguments: [1, 2, 3, 4, 5, 6, 9, 10, 11, 13, 16, 19] as [UInt8])
  func fixedLengthOpcodesRejectEveryTruncation(opcode: UInt8) throws {
    let expectedLengths: [UInt8: Int] = [
      1: 0, 2: 8, 3: 8, 4: 8, 5: 25, 6: 12, 9: 8,
      10: 5, 11: 5, 13: 20, 16: 12, 19: 12,
    ]
    let message = [opcode] + [UInt8](repeating: 0, count: try #require(expectedLengths[opcode]))
    let core = Core()
    #expect(core.valid(message))
    for count in 0..<message.count { #expect(!core.valid(Array(message.prefix(count)))) }
    #expect(!core.valid(message + [0]))
  }

  @Test func boundedFuzzRejectsBeforeDispatch() throws {
    let core = Core()
    sa_test_reset()
    var seed: UInt64 = 0x52fa_b123
    let messages = fixtures()
    for iteration in 0..<10_000 {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1
      var message = messages[iteration % messages.count]
      let index = Int(seed % UInt64(message.count))
      message[index] = UInt8(truncatingIfNeeded: seed >> 32)
      if !core.valid(message) {
        let count = sa_test_commands()
        let digest = sa_test_digest()
        #expect(try exchange(core, framed(message)) == [UInt8(SA_REPLY_INVALID)])
        #expect(sa_test_commands() == count)
        #expect(sa_test_digest() == digest)
      }
    }
    #expect(!core.valid([UInt8](repeating: 0, count: 4095)))
  }

  private func exchange(_ core: Core, _ bytes: [UInt8], fragment: Bool = false) throws -> [UInt8] {
    let pair = try #require(socketPair())
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      _ = core.serve(pair.1)
      close(pair.1)
      group.leave()
    }
    defer {
      close(pair.0)
      group.wait()
    }
    if fragment {
      for var byte in bytes {
        _ = send(pair.0, &byte, 1, 0)
        usleep(100)
      }
    } else {
      _ = bytes.withUnsafeBytes { send(pair.0, $0.baseAddress, $0.count, 0) }
    }
    shutdown(pair.0, SHUT_WR)
    var result: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let count = buffer.withUnsafeMutableBytes { recv(pair.0, $0.baseAddress, $0.count, 0) }
      if count <= 0 { break }
      result.append(contentsOf: buffer.prefix(count))
    }
    return result
  }

  @Test func recordedDispatchAndResponses() throws {
    let core = Core()
    sa_test_reset()
    for message in fixtures() {
      let response = try exchange(core, framed(message), fragment: true)
      if message[0] == 1 {
        #expect(response == Array("recording".utf8) + [0] + packed(sa_native_attributes()) + [10])
      } else {
        #expect(response == [UInt8(SA_REPLY_ACCEPTED)])
      }
    }
    #expect(sa_test_commands() == 14)
    // FNV-1a of the ordered fixture packets.
    // Preserve the comparison's native-call order without retaining a second implementation.
    #expect(sa_test_digest() == 0x9982_7767_6843_3409)
    #expect(try exchange(core, framed([20] + packed(Int32(100)))) == [UInt8(SA_REPLY_INVALID)])
    #expect(sa_test_commands() == 14)
    #expect(try exchange(core, [255, 127]) == [UInt8(SA_REPLY_INVALID)])
    #expect(try exchange(core, [3, 0, 2]) == [UInt8(SA_REPLY_INVALID)])
  }

  @Test func stalledAndTricklingClientsHaveAbsoluteDeadline() throws {
    let core = Core()
    let pair = try #require(socketPair())
    let start = DispatchTime.now().uptimeNanoseconds
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
      for var byte: UInt8 in [9, 0, 2, 1, 0, 0, 0, 0, 0, 0, 0] {
        if send(pair.0, &byte, 1, 0) <= 0 { break }
        usleep(150_000)
      }
      close(pair.0)
      group.leave()
    }
    _ = core.serve(pair.1)
    close(pair.1)
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    #expect(elapsed >= 0.9 && elapsed < 1.8)
    group.wait()
  }

  @Test func interruptedPollResumesTheSameRequest() throws {
    let pair = try #require(socketPair())
    try #require(sa_test_interrupt_begin(pair.1))
    for _ in 0..<3 {
      usleep(10_000)
      #expect(sa_test_interrupt_signal() == 0)
    }
    let request = framed(fixtures()[1])
    #expect(request.withUnsafeBytes { send(pair.0, $0.baseAddress, $0.count, 0) } == request.count)
    var reply: UInt8 = 255
    #expect(recv(pair.0, &reply, 1, 0) == 1)
    #expect(reply == SA_REPLY_ACCEPTED)
    close(pair.0)
    #expect(sa_test_interrupt_end() == 3)
  }

  @Test func boundedPatternAndInstructionDecoding() {
    let bytes: [UInt8] = [0xa8, 0, 0xb8, 0]
    var offsets = [Int](repeating: 0, count: 4)
    let matches = bytes.withUnsafeBufferPointer { buffer in
      sa_pattern_scan(buffer.baseAddress, buffer.count, "?8 00", &offsets, offsets.count)
    }
    #expect(matches == 2 && offsets[0] == 0 && offsets[1] == 2)
    #expect(
      bytes.withUnsafeBufferPointer { sa_pattern_scan($0.baseAddress, 1, "A8 00", nil, 0) } == 0)
    #expect(
      bytes.withUnsafeBufferPointer { sa_pattern_scan($0.baseAddress, $0.count, "GG", nil, 0) } == 0
    )
    var target: UInt64 = 0
    #expect(sa_decode_adrp_add(0xb000_1ec8, 0x912e_c108, 0x1_0003_0a98, &target))
    #expect(target == 0x1_0040_9bb0)
    #expect(!sa_decode_adrp_add(0, 0, 0, &target))
    #expect(!sa_decode_adrp_add(0xb000_1ec8, 0x912e_c109, 0, &target))
  }

  @Test(arguments: [Int64(26), Int64(27), Int64(28)])
  func osVersionSupportIsLimitedToMajor27(_ majorVersion: Int64) {
    #expect(sa_os_version_supported(majorVersion) == (majorVersion == 27))
  }

  @Test func uniquePatternMustBeAligned() {
    var offset = 0
    var matchCount = 0

    let alignedBytes: [UInt8] = [0xaa, 0xbb, 0]
    let aligned = alignedBytes.withUnsafeBufferPointer {
      sa_pattern_find_unique_aligned(
        $0.baseAddress, $0.count, "AA BB", 0x1000, &offset, &matchCount)
    }
    #expect(aligned && offset == 0 && matchCount == 1)

    let offsetBytes: [UInt8] = [0, 0xaa, 0xbb]
    let alignedOffset = offsetBytes.withUnsafeBufferPointer {
      sa_pattern_find_unique_aligned(
        $0.baseAddress, $0.count, "AA BB", 0x1003, &offset, &matchCount)
    }
    #expect(alignedOffset && offset == 1 && matchCount == 1)

    let unaligned = offsetBytes.withUnsafeBufferPointer {
      sa_pattern_find_unique_aligned(
        $0.baseAddress, $0.count, "AA BB", 0x1000, &offset, &matchCount)
    }
    #expect(!unaligned && offset == 1 && matchCount == 1)

    let ambiguousBytes: [UInt8] = [0xaa, 0xbb, 0xaa, 0xbb]
    let ambiguous = ambiguousBytes.withUnsafeBufferPointer {
      sa_pattern_find_unique_aligned(
        $0.baseAddress, $0.count, "AA BB", 0x1000, &offset, &matchCount)
    }
    #expect(!ambiguous && matchCount == 2)

    let missingBytes: [UInt8] = [0]
    let missing = missingBytes.withUnsafeBufferPointer {
      sa_pattern_find_unique_aligned(
        $0.baseAddress, $0.count, "AA BB", 0x1000, &offset, &matchCount)
    }
    #expect(!missing && matchCount == 0)
  }
}
