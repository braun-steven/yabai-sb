import Testing

//
// NOTE: Swift Testing runs tests in parallel. The tests that change or read the global managers (the state of the
// daemon) are nested in this suite, which runs them one at a time.
//

@Suite(.serialized)
struct DaemonState {}
