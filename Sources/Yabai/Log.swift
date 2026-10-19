import CPrivate
import Darwin

//
// NOTE: The logging and the exits of the daemon. Swift cannot call the variadic C logging functions, so the text is
// written with fputs to the stdout_global and stderr_global streams. debug writes to the stdout of C (stdout_global)
// so it stays ordered with C output.
//

enum Log
{
    /// Set by --verbose and debug_output, before the threads start or on the event loop; read anywhere.
    nonisolated(unsafe) static var verbose = false
}

/// Writes the text to stdout when the daemon runs with --verbose (or debug_output on).
func debug(_ text: @autoclosure () -> String)
{
    guard Log.verbose else { return }
    fputs(text(), stdout_global())
}

/// The prefix and the null-separated tokens of a message, up to the empty token that ends it.
func debugMessage(_ prefix: String, _ message: UnsafeMutablePointer<CChar>?)
{
    guard Log.verbose, var message else { return }

    fputs("\(prefix):", stdout_global())

    while message.pointee != 0 {
        fputs(" ", stdout_global())
        fputs(message, stdout_global())
        message += strlen(message) + 1
    }

    putc(0x0a, stdout_global())
    fflush(stdout_global())
}

func warn(_ text: String)
{
    fputs(text, stderr_global())
}

/// Exits with EXIT_FAILURE.
func error(_ text: String) -> Never
{
    fputs(text, stderr_global())
    exit(EXIT_FAILURE)
}

/// Exits with EXIT_SUCCESS.
func require(_ text: String) -> Never
{
    fputs(text, stderr_global())
    exit(EXIT_SUCCESS)
}

/// A user notification titled yabai (NotifyC in Sources/CPrivate/Notify.m).
func notify(_ subtitle: String, _ text: String)
{
    NotifyC(subtitle, text)
}
