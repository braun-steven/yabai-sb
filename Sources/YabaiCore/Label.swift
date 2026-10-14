/// A label names a display or a space (id). Ported from `struct label` (src/misc/label.h).
public struct Label: Equatable, Sendable
{
    public var id: UInt64
    public var name: String

    public init(id: UInt64, name: String)
    {
        self.id = id
        self.name = name
    }
}

//
// NOTE: A list holds each id and each name at most once. Names compare byte for byte, like string_equals,
// not by Swift's canonical equivalence: "é" precomposed and decomposed are two names.
//

public struct LabelList: Sendable
{
    public private(set) var labels: [Label] = []

    public init() {}

    private func index(id: UInt64) -> Int?
    {
        labels.firstIndex { $0.id == id }
    }

    private func index(name: String) -> Int?
    {
        labels.firstIndex { $0.name.utf8.elementsEqual(name.utf8) }
    }

    /// `label_find_id`
    public func find(id: UInt64) -> Label?
    {
        index(id: id).map { labels[$0] }
    }

    /// `label_find_name`
    public func find(name: String) -> Label?
    {
        index(name: name).map { labels[$0] }
    }

    /// `label_remove_at`: moves the last label into the gap, like buf_del.
    private mutating func remove(at index: Int)
    {
        labels.swapAt(index, labels.count - 1)
        labels.removeLast()
    }

    /// `label_remove_id`
    @discardableResult
    public mutating func remove(id: UInt64) -> Bool
    {
        guard let index = index(id: id) else { return false }

        remove(at: index)
        return true
    }

    //
    // NOTE: A name that labels another id moves to this id.
    //

    /// `label_set`
    public mutating func set(id: UInt64, name: String)
    {
        remove(id: id)

        if let index = index(name: name) {
            remove(at: index)
        }

        labels.append(Label(id: id, name: name))
    }

    /// The label of id moves to newID: space_manager_handle_display_add (src/space_manager.c) keeps the label of
    /// a space whose id changed.
    public mutating func replace(id: UInt64, with newID: UInt64)
    {
        guard let index = index(id: id) else { return }
        labels[index].id = newID
    }

    /// The labels of two ids trade places: space_manager_swap_space_with_space_on_display (src/space_manager.c).
    public mutating func swap(_ a: UInt64, _ b: UInt64)
    {
        for i in labels.indices {
            if labels[i].id == a {
                labels[i].id = b
            } else if labels[i].id == b {
                labels[i].id = a
            }
        }
    }
}
