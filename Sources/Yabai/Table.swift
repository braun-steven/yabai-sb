import Darwin
import YabaiCore

//
// NOTE: The hash table of the managers. The query responses list windows, applications and spaces in the order of
// the table, so this keeps the layout of src/misc/hashtable.h: one chain per bucket, a new key goes to the end of its
// chain, and the capacity doubles when the load passes 0.75, moving the entries bucket by bucket. values lists them in
// that order, like table_for. Adding a key that is already there keeps the old value, as table_add did.
//

/// `struct table` (src/misc/hashtable.h)
struct Table<Key, Value>
{
    private var buckets: [[(key: Key, value: Value)]]
    private let hash: (Key) -> UInt
    private let equals: (Key, Key) -> Bool
    private(set) var count = 0

    /// `table_init`
    init(capacity: Int, hash: @escaping (Key) -> UInt, equals: @escaping (Key, Key) -> Bool)
    {
        self.buckets = Array(repeating: [], count: capacity)
        self.hash = hash
        self.equals = equals
    }

    var capacity: Int { buckets.count }

    private func bucket(_ key: Key) -> Int
    {
        Int(hash(key) % UInt(buckets.count))
    }

    /// `table_rehash`
    private mutating func rehash()
    {
        let oldBuckets = buckets
        buckets = Array(repeating: [], count: 2 * oldBuckets.count)

        for chain in oldBuckets {
            for entry in chain {
                buckets[bucket(entry.key)].append(entry)
            }
        }
    }

    /// `table_add`
    mutating func add(_ key: Key, _ value: Value)
    {
        let index = bucket(key)
        if buckets[index].contains(where: { equals($0.key, key) }) { return }

        buckets[index].append((key, value))
        count += 1

        let load = Float(count) / Float(buckets.count)
        if load > 0.75 {
            rehash()
        }
    }

    /// `table_remove`
    mutating func remove(_ key: Key)
    {
        let index = bucket(key)
        guard let position = buckets[index].firstIndex(where: { equals($0.key, key) }) else { return }

        buckets[index].remove(at: position)
        count -= 1
    }

    /// `table_find`
    func find(_ key: Key) -> Value?
    {
        buckets[bucket(key)].first(where: { equals($0.key, key) })?.value
    }

    /// `table_for`: the values in the order of the buckets.
    var values: [Value]
    {
        var result: [Value] = []
        result.reserveCapacity(count)

        for chain in buckets {
            for entry in chain {
                result.append(entry.value)
            }
        }

        return result
    }

    /// `table_free`
    mutating func removeAll()
    {
        buckets = Array(repeating: [], count: buckets.count)
        count = 0
    }
}

extension Table where Key == WindowID
{
    /// `hash_wm` and `compare_wm`: window ids.
    init(capacity: Int)
    {
        self.init(capacity: capacity, hash: { UInt($0.rawValue) }, equals: { $0 == $1 })
    }
}

extension Table where Key == pid_t
{
    /// `hash_wm` and `compare_wm`, which read a pid as its 32 bits.
    init(capacity: Int)
    {
        self.init(capacity: capacity, hash: { UInt(UInt32(bitPattern: $0)) }, equals: { $0 == $1 })
    }
}

extension Table where Key == SpaceID
{
    /// The spaces of the space manager, by id.
    init(capacity: Int)
    {
        self.init(capacity: capacity, hash: { UInt($0.rawValue) }, equals: { $0 == $1 })
    }
}
