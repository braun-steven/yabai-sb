import Testing
import YabaiCore
@testable import Yabai

// NOTE: A destroyed space and a removed display are described by their id alone, without the managers.

@Test("event_signal_describe_spaces") func eventSignalDescribeSpaces()
{
    var es = PendingSignal(.spaceDestroyed)
    es.describeSpace(.space(1234))
    #expect(es.arguments.count == 1)
    #expect(es.arguments[0].name == "YABAI_SPACE_ID")
    #expect(es.arguments[0].value == "1234")

    var display = PendingSignal(.displayRemoved)
    display.describeDisplay(.display(5))
    #expect(display.arguments.count == 1)
    #expect(display.arguments[0].value == "5")
}
