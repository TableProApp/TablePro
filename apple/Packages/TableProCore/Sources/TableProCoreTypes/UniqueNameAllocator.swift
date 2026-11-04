// Gives each base name the lowest free ordinal, starting at 1. Remembering where each base
// stopped keeps a run of repeated names linear: the ordinals below the mark are taken for good,
// because a name, once taken, stays taken.
public struct UniqueNameAllocator {
    private var taken: Set<String>
    private var nextOrdinal: [String: Int] = [:]
    private let key: (String) -> String
    private let candidate: (String, Int) -> String

    public init(
        taken: [String] = [],
        key: @escaping (String) -> String = { $0 },
        candidate: @escaping (_ base: String, _ ordinal: Int) -> String
    ) {
        self.key = key
        self.candidate = candidate
        self.taken = Set(taken.map(key))
    }

    public func contains(_ name: String) -> Bool {
        taken.contains(key(name))
    }

    @discardableResult
    public mutating func reserve(_ name: String) -> Bool {
        taken.insert(key(name)).inserted
    }

    public mutating func allocate(_ base: String) -> String {
        var ordinal = nextOrdinal[base, default: 1]
        while true {
            let name = candidate(base, ordinal)
            ordinal += 1
            if taken.insert(key(name)).inserted {
                nextOrdinal[base] = ordinal
                return name
            }
        }
    }
}
