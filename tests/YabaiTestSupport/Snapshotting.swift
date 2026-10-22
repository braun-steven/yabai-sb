import SnapshotTesting

//
// NOTE: Snapshot strategies of the test targets. Text snapshots keep diffs readable in review: one line per element.
//

extension Snapshotting
where Value: Sequence, Value.Element: CustomStringConvertible, Format == String {
  /// The description of each element on its own line, e.g. the placements of a headless flush.
  public static var descriptionLines: Snapshotting {
    SimplySnapshotting.lines.pullback { $0.map(\.description).joined(separator: "\n") }
  }
}
