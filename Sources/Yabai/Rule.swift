import CPrivate
import YabaiCore

extension Rule {
  /// Resolve display and space indices only while building the wire response.
  @WM func info(index: Int, matched: Bool = false) -> RuleInfo {
    info(
      index: index, display: effects.did.flatMap { $0.arrangement } ?? 0,
      space: effects.sid.flatMap { $0.missionControlIndex } ?? 0, matched: matched)
  }
}
