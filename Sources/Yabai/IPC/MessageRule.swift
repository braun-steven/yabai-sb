import YabaiCore

@WM func handleDomainRule(_ rsp: inout Response, _ domain: Token, _ message: inout Message)
  throws(CommandError)
{
  let command = try RuleCommand.parse(&message, DaemonSelectorContext())
  switch command {
  case .add(let rule):
    WindowManager.shared.addRule(rule)
  case .apply(let target):
    switch target {
    case .all:
      WindowManager.shared.reapplyAllRules()
    case .index(let index):
      if !WindowManager.shared.reapplyRule(at: index) {
        throw CommandError("rule with index '\(index)' not found.\n")
      }
    case .labelOrInline(let label, let inline):
      if !WindowManager.shared.reapplyRule(label: label.string) {
        switch inline {
        case .success(let rule):
          if let rule { WindowManager.shared.applyRule(rule) }
        case .failure(let error): throw error
        }
      }
    }
  case .remove(let selector):
    switch selector {
    case .index(let index):
      if !WindowManager.shared.removeRule(at: index) {
        throw CommandError("rule with index '\(index)' not found.\n")
      }
    case .label(let label):
      if !WindowManager.shared.removeRule(label: label.string) {
        throw CommandError("rule with label '\(label)' not found.\n")
      }
    }
  case .list:
    rsp.write(json: .rules(WindowManager.shared.ruleInfos()))
  case .ignore:
    break
  }
}
