//
// NOTE: The labels of displays or spaces. A list holds each id and each name at most once, and a name that labels
// another id moves to the new id. Names compare as Swift strings, by canonical equivalence: "é" precomposed and
// decomposed are one name.
//

public struct LabelList<ID: Hashable & Sendable>: Sendable
{
    private var names: [ID: String] = [:]
    private var ids: [String: ID] = [:]

    public init() {}

    public var count: Int { names.count }

    /// The label of an id.
    public func name(of id: ID) -> String?
    {
        names[id]
    }

    /// The id that a name labels.
    public func id(named name: String) -> ID?
    {
        ids[name]
    }

    @discardableResult
    public mutating func remove(id: ID) -> Bool
    {
        guard let name = names.removeValue(forKey: id) else { return false }

        ids[name] = nil
        return true
    }

    public mutating func set(id: ID, name: String)
    {
        remove(id: id)

        if let previous = ids[name] { names[previous] = nil }

        names[id] = name
        ids[name] = id
    }

    /// The label of id moves to newID: `SpaceManager.handleDisplayAdd(_:)` keeps the label of a space whose id changed.
    public mutating func replace(id: ID, with newID: ID)
    {
        guard let name = names.removeValue(forKey: id) else { return }

        remove(id: newID)
        names[newID] = name
        ids[name] = newID
    }

    /// The labels of two ids trade places: `SpaceManager.swapSpaceAcrossDisplays` in the daemon.
    public mutating func swap(_ a: ID, _ b: ID)
    {
        let nameA = names[a], nameB = names[b]

        names[a] = nameB
        names[b] = nameA
        if let nameA { ids[nameA] = b }
        if let nameB { ids[nameB] = a }
    }
}
