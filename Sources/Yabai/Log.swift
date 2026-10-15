import CPrivate
import Darwin

//
// NOTE: The output of src/misc/log.h and src/misc/notify.h for Swift, which cannot call the variadic C functions.
// debug writes to the stdout of C, so the lines keep their order with the C debug output.
//

/// `g_verbose`: set by --verbose and debug_output, before the threads start or on the event loop; read anywhere.
nonisolated(unsafe) var g_verbose = false

/// `debug`: writes the text to stdout when the daemon runs with --verbose (or debug_output on).
func debug(_ text: @autoclosure () -> String)
{
    guard g_verbose else { return }
    fputs(text(), stdout_global())
}

/// `debug_message`: the prefix and the null-separated tokens of a message, up to the empty token that ends it.
func debug_message(_ prefix: String, _ message: UnsafeMutablePointer<CChar>?)
{
    guard g_verbose, var message else { return }

    fputs("\(prefix):", stdout_global())

    while message.pointee != 0 {
        fputs(" ", stdout_global())
        fputs(message, stdout_global())
        message += strlen(message) + 1
    }

    putc(0x0a, stdout_global())
    fflush(stdout_global())
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
