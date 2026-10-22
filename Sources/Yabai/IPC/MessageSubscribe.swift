import YabaiCore

//
// NOTE: `subscribe` writes its first line, then asks the message loop to keep the socket open (Response.subscribedTypes).
// The loop hands the socket to EventSubscribers.add, which writes that line before any event. The failure of an unknown
// event is an ordinary failure response, and the socket closes as for any other message.
//

/// Runs `yabai -m subscribe [<event>…]`.
func handleDomainSubscribe(_ response: inout Response, _ message: inout some TokenSource)
  throws(CommandError)
{
  let types = try SubscribeCommand.parse(&message)
  try response.write(json: SubscribeCommand.subscribedLine(types))
  response.subscribedTypes = types
}
