import CPrivate
import Darwin
import YabaiC

//
// NOTE: The output of src/misc/log.h and src/misc/notify.h for Swift, which cannot call the variadic C functions.
// debug writes to the stdout of C, so the lines keep their order with the C debug output.
//

/// `debug`: writes the text to stdout when the daemon runs with --verbose (or debug_output on).
func debug(_ text: @autoclosure () -> String)
{
    guard verbose_global()!.pointee else { return }
    fputs(text(), stdout_global())
}

/// `warn`
func warn(_ text: String)
{
    fputs(text, stderr_global())
}

/// `error`: exits with EXIT_FAILURE.
func error(_ text: String) -> Never
{
    fputs(text, stderr_global())
    exit(EXIT_FAILURE)
}

/// `require`: exits with EXIT_SUCCESS.
func require(_ text: String) -> Never
{
    fputs(text, stderr_global())
    exit(EXIT_SUCCESS)
}

/// `notify`: a user notification titled yabai (NotifyC in Sources/CPrivate/Notify.m).
func notify(_ subtitle: String, _ text: String)
{
    NotifyC(subtitle, text)
}
