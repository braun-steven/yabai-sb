import CPrivate
import YabaiCore

extension Rule {
  /// Resolve display and space indices only while building the wire response.
  @WM func info(index: Int, matched: Bool = false) -> RuleInfo {
    info(
      index: index, display: effects.did.flatMap { $0.arrangement } ?? 0,
      space: effects.currentSpace.flatMap { $0.missionControlIndex } ?? 0, matched: matched)
  }
}

extension RuleEffects {
  /// The space of the rule now; nil without one, or when no space has its index or label.
  @WM var currentSpace: SpaceID? {
    switch space {
    case .id(let sid): sid
    case .selector(let selector):
      try? selector.resolve(acting: SpaceID.active, DaemonSelectorContext())
    case nil: nil
    }
  }
}
