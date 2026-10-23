//
// NOTE: A renderer keeps the key of what it drew last. A render whose key equals that key would draw the same thing, so
// the drawing is skipped and the caller only orders the window again. The key must hold every input of the drawing
// (geometry, content, style, config generation and anything read from the system), or a skipped draw leaves a stale
// view. This type compares keys only; it knows nothing about the drawing.
//

/// The draw decision of a renderer: draw when the key differs from the key of the last draw, or when nothing was drawn.
public struct RenderGate<Key: Equatable> {
  private var last: Key?

  public init() {}

  /// Returns true when `key` must be drawn. The key then becomes the last drawn key, so the caller draws whenever it
  /// returns true.
  public mutating func needsDraw(_ key: Key) -> Bool {
    if last == key { return false }
    last = key
    return true
  }

  /// Forgets the last drawn key, so that the next key is drawn, whatever it is.
  public mutating func reset() {
    last = nil
  }
}
