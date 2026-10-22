import Darwin
import Dispatch
import Testing
import OSAXCoreAPI
import RecordingAdapter
import Fixtures
import SwiftPayloadCore
import LoaderFixture

@Suite(.serialized) struct PayloadTests
{
    @Test func loaderCompletionFailureAndCleanup()
    {
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

    @Test func allOpcodesAndTruncations()
    {
        let core = Core()
        for message in fixtures() {
            #expect(core.valid(message))
            for count in 0..<message.count { #expect(!core.valid(Array(message.prefix(count)))) }
            #expect(!core.valid(message + [0]))
        }
        #expect(!core.valid([0]))
        #expect(!core.valid([255]))
        for opcode: UInt8 in [14, 15, 17, 20] {
            #expect(!core.valid([opcode] + packed(Int32(-1))))
            #expect(!core.valid([opcode] + packed(Int32.max)))
            #expect(core.valid([opcode] + packed(Int32(0))))
        }
        #expect(!core.valid([18] + packed(UInt64(1)) + packed(Int32(-1))))
        #expect(!core.valid([8] + packed(UInt32(7)) + packed(Float.nan) + packed(Float(1))))
        #expect(!core.valid([8] + packed(UInt32(7)) + packed(Float(0.5)) + packed(Float.infinity)))
        #expect(!core.valid([10] + packed(UInt32(7)) + [2]))
    }

    @Test func boundedFuzzRejectsBeforeDispatch() throws
    {
        let core = Core()
        sa_test_reset()
        var seed: UInt64 = 0x52fab123
        for iteration in 0..<10_000 {
            seed = seed &* 6364136223846793005 &+ 1
            var message = fixtures()[iteration % 20]
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

    private func exchange(_ core: Core, _ bytes: [UInt8], fragment: Bool = false) throws -> [UInt8]
    {
        let pair = try #require(socketPair())
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            _ = core.serve(pair.1)
            close(pair.1)
            group.leave()
        }
        defer { close(pair.0); group.wait() }
        if fragment {
            for var byte in bytes { _ = send(pair.0, &byte, 1, 0); usleep(100) }
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

    @Test func recordedDispatchAndResponses() throws
    {
        let core = Core()
        sa_test_reset()
        for message in fixtures() {
            let response = try exchange(core, framed(message), fragment: true)
            if message[0] == 1 {
                #expect(response == Array("recording".utf8) + [0] + packed(sa_native_attributes()) + [10])
            } else {
                #expect(response == [message[0] == 12 ? UInt8(SA_REPLY_UNSUPPORTED) : UInt8(SA_REPLY_ACCEPTED)])
            }
        }
        #expect(sa_test_commands() == 19)
        // FNV-1a of ordered fixture packets plus the immediate alpha write's wid/alpha bytes.
        // Preserve the comparison's native-call order without retaining a second implementation.
        #expect(sa_test_digest() == 0x48f66fb99d562774)
        #expect(try exchange(core, framed([20] + packed(Int32(100)))) == [UInt8(SA_REPLY_INVALID)])
        #expect(sa_test_commands() == 19)
        #expect(try exchange(core, [255, 127]) == [UInt8(SA_REPLY_INVALID)])
        #expect(try exchange(core, [3, 0, 2]) == [UInt8(SA_REPLY_INVALID)])
    }

    @Test func stalledAndTricklingClientsHaveAbsoluteDeadline() throws
    {
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

    @Test func interruptedPollResumesTheSameRequest() throws
    {
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

    @Test func fadeReplacementCancellationAndBackendFailures()
    {
        let core = Core()
        sa_test_reset()
        #expect(core.opacity(7, 0, 1, 0))
        _ = core.tick(500_000_000)
        #expect(abs(sa_test_alpha(7) - 0.5) < 0.00001)
        #expect(core.opacity(7, 1, 1, 500_000_000))
        _ = core.tick(1_000_000_000)
        #expect(abs(sa_test_alpha(7) - 0.75) < 0.00001)
        #expect(core.opacity(7, 0.2, 0, 1_000_000_000))
        _ = core.tick(3_000_000_000)
        #expect(sa_test_alpha(7) == 0.2)
        sa_test_fail(true, false)
        #expect(!core.opacity(7, 1, 1, 0))
        sa_test_fail(false, true)
        #expect(!core.opacity(7, 1, 0, 0))
        sa_test_fail(false, false)
        #expect(!core.opacity(7, .nan, 1, 0))
        #expect(!core.opacity(7, 1, -.infinity, 0))
        #expect(core.opacity(7, 1, 1, 0))
        sa_test_fail(false, true)
        _ = core.tick(500_000_000)
        sa_test_fail(false, false)
        _ = core.tick(2_000_000_000)
        #expect(sa_test_alpha(7) == 0.2)
    }

    @Test func fadeTimerStateFollowsActiveFades()
    {
        let core = Core()
        sa_test_reset()
        #expect(!sa_swift_has_fades())
        // An immediate write never leaves a fade behind, so the timer would have nothing to do.
        #expect(core.opacity(7, 1, 0, 0))
        #expect(!sa_swift_has_fades())
        #expect(!core.tick(0))
        #expect(core.opacity(7, 0, 1, 0))
        #expect(sa_swift_has_fades())
        #expect(core.tick(500_000_000))
        #expect(sa_swift_has_fades())
        // The completing tick removes the fade and reports that none remain.
        #expect(!core.tick(2_000_000_000))
        #expect(!sa_swift_has_fades())
        #expect(sa_test_alpha(7) == 0)
    }

    @Test func concurrentFadesAndImmediateCommands()
    {
        let core = Core()
        sa_test_reset()
        DispatchQueue.concurrentPerform(iterations: 1000) { index in
            _ = core.opacity(UInt32(index % 32 + 1), Float(index % 10) / 10, index % 3 == 0 ? 0 : 1, UInt64(index))
            _ = core.tick(UInt64(index))
        }
        #expect(core.opacity(7, 0.25, 0, 2000))
        _ = core.tick(10_000_000_000)
        #expect(sa_test_alpha(7) == 0.25)
    }

    @Test func boundedPatternAndInstructionDecoding()
    {
        let bytes: [UInt8] = [0xa8, 0, 0xb8, 0]
        var offsets = [Int](repeating: 0, count: 4)
        let matches = bytes.withUnsafeBufferPointer { buffer in
            sa_pattern_scan(buffer.baseAddress, buffer.count, "?8 00", &offsets, offsets.count)
        }
        #expect(matches == 2 && offsets[0] == 0 && offsets[1] == 2)
        #expect(bytes.withUnsafeBufferPointer { sa_pattern_scan($0.baseAddress, 1, "A8 00", nil, 0) } == 0)
        #expect(bytes.withUnsafeBufferPointer { sa_pattern_scan($0.baseAddress, $0.count, "GG", nil, 0) } == 0)
        var target: UInt64 = 0
        #expect(sa_decode_adrp_add(0xb0001ec8, 0x912ec108, 0x100030a98, &target))
        #expect(target == 0x100409bb0)
        #expect(!sa_decode_adrp_add(0, 0, 0, &target))
        #expect(!sa_decode_adrp_add(0xb0001ec8, 0x912ec109, 0, &target))
    }
}
