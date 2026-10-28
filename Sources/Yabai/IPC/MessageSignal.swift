import YabaiCore

@WM func handleDomainSignal(
  _ rsp: inout Response, _ domain: Token, _ message: inout Message
) throws(CommandError) {
  let command = try SignalCommand.parse(&message)
  switch command {
  case .add(let signal, let type): EventSignals.shared.table.add(signal, type)
  case .remove(let selector):
    switch selector {
    case .index(let index):
      if !EventSignals.shared.table.remove(at: index) {
        throw CommandError("signal with index '\(index)' not found.\n")
      }
    case .label(let label):
      if !EventSignals.shared.table.remove(label: label.string) {
        throw CommandError("signal with label '\(label)' not found.\n")
      }
    }
  case .list:
    rsp.write(json: .signals(EventSignals.shared.table.list()))
  }
}
