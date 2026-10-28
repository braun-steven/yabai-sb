/// The state of the scripting addition, as `query --scripting-addition` reports it.
public struct ScriptingAdditionInfo: Encodable, Equatable, Sendable {
  /// A payload capability, one per attribute bit of the handshake (`OSAX_ATTRIB_*` in `osax/common.h`).
  public enum Capability: String, CodingKey, CaseIterable, Sendable {
    case dockSpaces = "dock-spaces"
    case desktopPictureManager = "desktop-picture-manager"
    case addSpace = "add-space"
    case removeSpace = "remove-space"
    case moveSpace = "move-space"
    case animationPatch = "animation-patch"

    /// The attribute bit of the capability.
    public var bit: UInt32 {
      switch self {
      case .dockSpaces: 0x01
      case .desktopPictureManager: 0x02
      case .addSpace: 0x04
      case .removeSpace: 0x08
      case .moveSpace: 0x10
      case .animationPatch: 0x40
      }
    }
  }

  private enum Key: String, CodingKey {
    case embedded, installed, loaded, capabilities
    case isCurrent = "is-current"
    case dockUUID = "dock-uuid"
    case dockBuildKnown = "dock-build-known"
    case sipCompatible = "sip-compatible"
  }

  /// The payload version this binary embeds.
  public var embedded: String
  /// The payload version installed in /Library/ScriptingAdditions; nil when none is installed.
  public var installed: String?
  /// The version of the payload that answers in Dock; nil when none answers.
  public var loaded: String?
  /// The attribute bits of the loaded payload; nil when none answers.
  public var attributes: UInt32?
  /// The LC_UUID of the Dock image the payload runs in; nil when the payload does not report it.
  public var dockUUID: String?
  /// Whether the payload validated that Dock build for the animation patch; nil when it does not report it.
  public var dockBuildKnown: Bool?
  /// Whether System Integrity Protection allows the payload (filesystem protections and debugging restrictions off).
  public var sipCompatible: Bool

  public init(
    embedded: String, installed: String?, loaded: String?, attributes: UInt32?, dockUUID: String?,
    dockBuildKnown: Bool?, sipCompatible: Bool
  ) {
    self.embedded = embedded
    self.installed = installed
    self.loaded = loaded
    self.attributes = attributes
    self.dockUUID = dockUUID
    self.dockBuildKnown = dockBuildKnown
    self.sipCompatible = sipCompatible
  }

  /// Whether the loaded payload is the one this binary embeds.
  public var isCurrent: Bool { loaded == embedded }

  /// Each capability and whether the attributes have its bit; all false when no payload answers.
  public static func capabilities(from attributes: UInt32?) -> [(Capability, Bool)] {
    Capability.allCases.map { ($0, (attributes ?? 0) & $0.bit != 0) }
  }

  private struct Capabilities: Encodable {
    var attributes: UInt32?

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: Capability.self)
      for (capability, present) in ScriptingAdditionInfo.capabilities(from: attributes) {
        try container.encode(present, forKey: capability)
      }
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    try container.encode(embedded, forKey: .embedded)
    try container.encode(installed, forKey: .installed)
    try container.encode(loaded, forKey: .loaded)
    try container.encode(isCurrent, forKey: .isCurrent)
    try container.encode(Capabilities(attributes: attributes), forKey: .capabilities)
    try container.encode(dockUUID, forKey: .dockUUID)
    try container.encode(dockBuildKnown, forKey: .dockBuildKnown)
    try container.encode(sipCompatible, forKey: .sipCompatible)
  }
}
