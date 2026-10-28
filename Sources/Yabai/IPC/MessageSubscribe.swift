import YabaiCore

/// A successful subscription explicitly transfers the connection to the event publisher.
func handleDomainSubscribe(_ response: inout Response, _ message: inout Message)
  throws(CommandError)
{
  response.disposition = .subscribe(try SubscribeCommand.parse(&message))
}
