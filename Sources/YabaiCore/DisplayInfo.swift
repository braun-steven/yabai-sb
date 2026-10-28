import CoreGraphics

/// A display in `query --displays`.
public struct DisplayInfo: Encodable, Sendable {
  public enum Key: String, CodingKey, CaseIterable, Sendable {
    case id, uuid, index, label, frame, spaces
    case hasFocus = "has-focus"
  }

  /// The keys that encode(to:) writes.
  public let properties: Set<Key>
  public var id: DisplayID
  public var uuid = ""
  public var index = 0
  public var label = ""
  public var frame = QueryFrame(.zero)
  /// The Mission Control indices of the spaces of the display.
  public var spaces: [Int] = []
  public var hasFocus = false

  public init(id: DisplayID, properties: Set<Key> = Set(Key.allCases)) {
    self.id = id
    self.properties = properties
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    for key in Key.allCases where properties.contains(key) {
      switch key {
      case .id: try container.encode(Int32(bitPattern: id.rawValue), forKey: key)
      case .uuid: try container.encode(uuid, forKey: key)
      case .index: try container.encode(index, forKey: key)
      case .label: try container.encode(label, forKey: key)
      case .frame: try container.encode(frame, forKey: key)
      case .spaces: try container.encode(spaces, forKey: key)
      case .hasFocus: try container.encode(hasFocus, forKey: key)
      }
    }
  }
}
