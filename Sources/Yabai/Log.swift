import Darwin
import YabaiC

//
// NOTE: The debug output of src/misc/log.h for Swift, which cannot call the variadic C functions. It writes to the
// stdout of C, so the lines keep their order with the C debug output.
//

/// `debug`: writes the text to stdout when the daemon runs with --verbose (or debug_output on).
func debug(_ text: @autoclosure () -> String)
{
    guard verbose_global()!.pointee else { return }
    fputs(text(), stdout_global())
}
