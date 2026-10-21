import ApplicationServices
import Darwin
import Testing
@testable import Yabai
import YabaiTestSupport

//
// NOTE: The pure helpers of `Sources/Yabai/Helpers.swift`. None of them touches the managers, so they run outside the
// DaemonState suite.
//

@Suite struct AnimationEasingTests
{
    /// The progress values of a curve check: every thousandth of the animation.
    static let steps = (0...1000).map { Float($0) / 1000 }

    @Test(arguments: AnimationEasing.allCases)
    func curveStartsAtZeroAndEndsAtOne(_ easing: AnimationEasing)
    {
        #expect(abs(easing.value(at: 0)) <= 1e-6)
        #expect(abs(easing.value(at: 1) - 1) <= 1e-6)
    }

    // NOTE: None of the curves overshoots (no back or elastic easing), so each one rises monotonically and stays in
    // 0...1. The tolerance allows for the rounding of Float.
    @Test(arguments: AnimationEasing.allCases)
    func curveRisesWithinTheUnitInterval(_ easing: AnimationEasing)
    {
        var previous = easing.value(at: 0)
        for t in Self.steps.dropFirst() {
            let value = easing.value(at: t)
            #expect(value >= previous - 1e-6, "\(easing.rawValue) falls at \(t): \(previous) -> \(value)")
            #expect(value >= -1e-6 && value <= 1 + 1e-6, "\(easing.rawValue) leaves 0...1 at \(t): \(value)")
            previous = value
        }
    }

    @Test(arguments: AnimationEasing.allCases.filter { $0.rawValue.contains("_in_out_") })
    func inOutCurveIsHalfwayAtTheMiddle(_ easing: AnimationEasing)
    {
        #expect(abs(easing.value(at: 0.5) - 0.5) <= 1e-6)
        // the two halves are point symmetric around the middle
        for t in Self.steps where t < 0.5 {
            #expect(abs(easing.value(at: t) + easing.value(at: 1 - t) - 1) <= 1e-5, "\(easing.rawValue) at \(t)")
        }
    }

    @Test func curvesAreNamedByTheirConfigValues()
    {
        #expect(AnimationEasing.allCases.count == 21)
        for easing in AnimationEasing.allCases {
            #expect(AnimationEasing(rawValue: easing.rawValue) == easing)
            #expect(easing.rawValue.hasPrefix("ease_"))
        }
        #expect(AnimationEasing(rawValue: "linear") == nil)
    }

    static let curveValues: [(AnimationEasing, Float, Float)] = [
        (.easeInQuad, 0.5, 0.25),
        (.easeOutQuad, 0.5, 0.75),
        (.easeInCubic, 0.5, 0.125),
        (.easeInQuart, 0.5, 0.0625),
        (.easeInQuint, 0.5, 0.03125),
        (.easeInExpo, 0.5, 0.03125),
        (.easeOutExpo, 0.5, 0.96875),
        (.easeInOutCubic, 0.25, 0.0625),
        (.easeInSine, 1.0 / 3, 0.1339746),
        (.easeOutCirc, 0.5, 0.8660254),
    ]

    @Test(arguments: curveValues)
    func curveValue(_ easing: AnimationEasing, _ t: Float, _ expected: Float)
    {
        #expect(abs(easing.value(at: t) - expected) <= 1e-6)
    }
}

@Suite struct HelperTests
{
    static let colors: [(UInt32, [Float])] = [
        (0x0000_0000, [0, 0, 0, 0]),
        (0xFFFF_FFFF, [1, 1, 1, 1]),
        (0xFF28_5577, [Float(0x28) / 255, Float(0x55) / 255, Float(0x77) / 255, 1]),
        (0x80FF_0000, [1, 0, 0, Float(0x80) / 255]),
        (0x0000_FF00, [0, 1, 0, 0]),
        (0x0000_00FF, [0, 0, 1, 0]),
    ]

    @Test(arguments: colors)
    func colorComponents(_ hex: UInt32, _ rgba: [Float])
    {
        let color = RGBAColor(hex: hex)
        #expect(color.argb == hex)
        #expect([color.r, color.g, color.b, color.a] == rgba)
    }

    @Test func emptyColorIsTransparentBlack()
    {
        #expect(RGBAColor() == RGBAColor(hex: 0))
    }

    static let radii: [(CGSize, Float, Float, Float)] = [
        (CGSize(width: 100, height: 40), 10, 10, 10),
        (CGSize(width: 100, height: 40), 20, 20, 20),
        (CGSize(width: 100, height: 40), 30, 30, 20),
        (CGSize(width: 100, height: 40), 60, 50, 20),
        (CGSize(width: 15, height: 9), 8, 7.5, 4.5),
        (CGSize(width: 0, height: 0), 4, 0, 0),
        (CGSize(width: 10, height: 10), 0, 0, 0),
    ]

    @Test(arguments: radii)
    func radiusIsLimitedToHalfTheSide(_ size: CGSize, _ radius: Float, _ x: Float, _ y: Float)
    {
        let rect = CGRect(origin: CGPoint(x: 7, y: -3), size: size)
        #expect(rect.clampedXRadius(radius) == x)
        #expect(rect.clampedYRadius(radius) == y)
    }

    static let edgePoints: [(CGPoint, Bool)] = [
        (CGPoint(x: 10, y: 20), true),
        (CGPoint(x: 110, y: 70), true),
        (CGPoint(x: 10, y: 70), true),
        (CGPoint(x: 60, y: 45), true),
        (CGPoint(x: 9.9, y: 45), false),
        (CGPoint(x: 110.1, y: 45), false),
        (CGPoint(x: 60, y: 70.1), false),
        (CGPoint(x: 60, y: 19.9), false),
    ]

    @Test(arguments: edgePoints)
    func rectContainsItsEdges(_ point: CGPoint, _ inside: Bool)
    {
        #expect(CGRect(x: 10, y: 20, width: 100, height: 50).containsIncludingEdges(point) == inside)
    }

    /// A triangle with its corners in counterclockwise and in clockwise order.
    static let triangles: [[CGPoint]] = [
        [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)],
        [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 10), CGPoint(x: 10, y: 0)],
    ]

    static let trianglePoints: [(CGPoint, Bool)] = [
        (CGPoint(x: 1, y: 1), true),
        (CGPoint(x: 4.9, y: 4.9), true),
        // the edges and corners are outside
        (CGPoint(x: 5, y: 0), false),
        (CGPoint(x: 0, y: 5), false),
        (CGPoint(x: 5, y: 5), false),
        (CGPoint(x: 0, y: 0), false),
        (CGPoint(x: 10, y: 0), false),
        (CGPoint(x: -1, y: 1), false),
        (CGPoint(x: 6, y: 6), false),
        (CGPoint(x: 1, y: -0.1), false),
    ]

    @Test(arguments: triangles, trianglePoints)
    func pointInTriangle(_ triangle: [CGPoint], _ row: (CGPoint, Bool))
    {
        #expect(row.0.isInTriangle(triangle) == row.1)
    }

    @Test func nothingIsInADegenerateTriangle()
    {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 10)]
        #expect(!CGPoint(x: 2, y: 2).isInTriangle(line))
        #expect(!CGPoint(x: 2, y: 3).isInTriangle(line))
        let point = [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 1)]
        #expect(!CGPoint(x: 1, y: 1).isInTriangle(point))
    }

    static let clampedValues: [(Float, Float)] = [
        (0.5, 0.5),
        (0.1, 0.1),
        (0.9, 0.9),
        (0.05, 0.1),
        (0.95, 0.9),
        (-3, 0.1),
        (.infinity, 0.9),
        (-.infinity, 0.1),
    ]

    @Test(arguments: clampedValues)
    func floatIsClamped(_ value: Float, _ expected: Float)
    {
        #expect(value.clamped(min: 0.1, max: 0.9) == expected)
    }

    static let intervals: [(UInt64, UInt64, Float)] = [
        (1_000_000, 3_500_000, 2.5),
        (5, 5, 0),
        (3_000_000, 1_000_000, -2),
        // a timestamp beyond the precision of a float still gives the exact interval
        (1 << 50, (1 << 50) + 16_000_000, 16),
        (UInt64.max - 999_999, 1_000_000, 2),
    ]

    @Test(arguments: intervals)
    func timerIntervalInMilliseconds(_ from: UInt64, _ to: UInt64, _ expected: Float)
    {
        #expect(abs(OSTimer.milliseconds(from: from, to: to) - expected) <= 1e-5)
    }

    @Test func timerRises()
    {
        let first = OSTimer.now
        let second = OSTimer.now
        #expect(first > 0)
        #expect(second >= first)
    }

    @Test func currentProcessIsTheSameAsItself()
    {
        let current = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kCurrentProcess))
        let none = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kNoProcess))
        #expect(current.isSame(as: current))
        #expect(!current.isSame(as: none))
    }

    @Test func socketConnectsToAListeningPath() throws
    {
        // a short path: sun_path holds 104 bytes
        let path = "/tmp/yabai-test-\(getpid()).socket"
        unlink(path)
        defer { unlink(path) }

        var server: Int32 = -1
        try #require(UnixSocket.open(&server))
        defer { UnixSocket.close(server) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(server, 1) == 0)

        var client: Int32 = -1
        try #require(UnixSocket.open(&client))
        defer { UnixSocket.close(client) }
        #expect(UnixSocket.connect(client, to: path))

        var missing: Int32 = -1
        try #require(UnixSocket.open(&missing))
        defer { UnixSocket.close(missing) }
        #expect(!UnixSocket.connect(missing, to: path + ".missing"))
    }
}
