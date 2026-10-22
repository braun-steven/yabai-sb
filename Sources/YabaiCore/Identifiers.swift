//
// NOTE: Window server ids keep the width SkyLight and CoreGraphics use for them: CGWindowID (UInt32), the managed
// space id CGSSpaceID (UInt64) and CGDirectDisplayID (UInt32). Code converts to the raw value only where it calls
// C (CPrivate, SkyLight, CoreGraphics) or writes the SA payload. No id is nil, never 0: `init?(nonzero:)` converts
// what the window server returns.
//

/// The window server id of a window (`CGWindowID`).
public struct WindowID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public var rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public init(_ rawValue: UInt32) { self.rawValue = rawValue }

  /// nil for 0, which the window server uses for no window.
  public init?(nonzero rawValue: UInt32) {
    if rawValue == 0 { return nil }
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }

  public static func < (a: WindowID, b: WindowID) -> Bool { a.rawValue < b.rawValue }
}

/// The window server id of a space (`CGSSpaceID`).
public struct SpaceID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public var rawValue: UInt64

  public init(rawValue: UInt64) { self.rawValue = rawValue }
  public init(_ rawValue: UInt64) { self.rawValue = rawValue }

  /// nil for 0, which the window server uses for no space.
  public init?(nonzero rawValue: UInt64) {
    if rawValue == 0 { return nil }
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }

  public static func < (a: SpaceID, b: SpaceID) -> Bool { a.rawValue < b.rawValue }
}

/// The CoreGraphics id of a display (`CGDirectDisplayID`).
public struct DisplayID: RawRepresentable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public var rawValue: UInt32

  public init(rawValue: UInt32) { self.rawValue = rawValue }
  public init(_ rawValue: UInt32) { self.rawValue = rawValue }

  /// nil for 0, which the window server uses for no display.
  public init?(nonzero rawValue: UInt32) {
    if rawValue == 0 { return nil }
    self.rawValue = rawValue
  }

  public var description: String { String(rawValue) }

  public static func < (a: DisplayID, b: DisplayID) -> Bool { a.rawValue < b.rawValue }
}
