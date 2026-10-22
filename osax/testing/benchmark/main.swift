import Darwin
import Dispatch
import Fixtures
import Foundation
import OSAXCoreAPI
import RecordingAdapter
import SwiftPayloadCore

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func statistics(_ samples: [UInt64]) -> [String: Double] {
  let sorted = samples.sorted()
  func percentile(_ p: Double) -> Double {
    Double(sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)])
  }
  return [
    "median_ns": percentile(0.5), "p95_ns": percentile(0.95), "p99_ns": percentile(0.99),
    "max_ns": Double(sorted.last!), "samples": Double(sorted.count),
  ]
}

guard CommandLine.arguments.count == 1 else { fatalError("usage: osax-benchmark") }
let core = Core()
sa_test_reset()
let messages = Array(fixtures().dropFirst())
let iterations = 20_000
var dispatchSamples: [UInt64] = []
dispatchSamples.reserveCapacity(iterations)
// Warm runtime metadata, autorelease pools and dictionary storage before measuring.
for i in 0..<1000 {
  autoreleasepool {
    let message = messages[i % messages.count]
    message.withUnsafeBufferPointer { _ = sa_native_dispatch($0.baseAddress, $0.count) }
    _ = core.tick(UInt64(i) * 8_000_000)
  }
}
sa_test_reset()
let logging = sa_test_allocations_start()
let dispatchStart = now()
for i in 0..<iterations {
  autoreleasepool {
    let message = messages[i % messages.count]
    let start = now()
    message.withUnsafeBufferPointer {
      if !core.validate($0.baseAddress, $0.count) { fatalError("valid fixture rejected") }
      _ = sa_native_dispatch($0.baseAddress, $0.count)
    }
    _ = core.tick(UInt64(i) * 8_000_000)
    dispatchSamples.append(now() - start)
  }
}
let dispatchElapsed = now() - dispatchStart
let allocationCount: UInt64? = logging ? sa_test_allocations_stop() : nil
var blocks: UInt64 = 0
var bytes: UInt64 = 0
var resident: UInt64 = 0
sa_test_memory(&blocks, &bytes, &resident)

var socketSamples: [UInt64] = []
let server = core.serve
for i in 0..<1200 {
  autoreleasepool {
    let pair = socketPair()!
    let message = framed(messages[i % messages.count])
    let group = DispatchGroup()
    group.enter()
    let start = now()
    DispatchQueue.global().async { [server] in
      _ = server(pair.1)
      close(pair.1)
      group.leave()
    }
    _ = message.withUnsafeBytes { send(pair.0, $0.baseAddress, $0.count, 0) }
    var byte: UInt8 = 0
    _ = recv(pair.0, &byte, 1, 0)
    close(pair.0)
    group.wait()
    if i >= 200 { socketSamples.append(now() - start) }
  }
}
let output: [String: Any] = [
  "mode": "swift", "scope": "isolated recording backend",
  "validate_dispatch": statistics(dispatchSamples), "socket_round_trip": statistics(socketSamples),
  "commands_per_second": Double(iterations) * 1e9 / Double(dispatchElapsed),
  "allocation_calls": allocationCount.map { $0 as Any } ?? NSNull(),
  "live_malloc_blocks": blocks, "live_malloc_bytes": bytes, "resident_bytes": resident,
  "digest": String(sa_test_digest(), radix: 16),
]
let data = try JSONSerialization.data(
  withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
