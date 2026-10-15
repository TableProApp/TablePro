import Foundation

/// The row keys a read may return: an interval, or a list of exact keys inside it.
struct BigtableKeyBounds {
    struct Bound {
        let key: Data
        let isClosed: Bool
    }

    var start: Bound?
    var end: Bound?
    var exact: [Data]?

    var isUnbounded: Bool {
        start == nil && end == nil && exact == nil
    }

    var isEmpty: Bool {
        if let exact {
            return !exact.contains(where: admits)
        }
        guard let start, let end else { return false }
        if end.key.lexicographicallyPrecedes(start.key) { return true }
        return start.key == end.key && !(start.isClosed && end.isClosed)
    }

    mutating func raiseStart(_ key: Data, closed: Bool) {
        guard let current = start else {
            start = Bound(key: key, isClosed: closed)
            return
        }
        if current.key.lexicographicallyPrecedes(key) {
            start = Bound(key: key, isClosed: closed)
        } else if current.key == key {
            start = Bound(key: key, isClosed: closed && current.isClosed)
        }
    }

    mutating func lowerEnd(_ key: Data, closed: Bool) {
        guard let current = end else {
            end = Bound(key: key, isClosed: closed)
            return
        }
        if key.lexicographicallyPrecedes(current.key) {
            end = Bound(key: key, isClosed: closed)
        } else if current.key == key {
            end = Bound(key: key, isClosed: closed && current.isClosed)
        }
    }

    mutating func restrict(to keys: [Data]) {
        exact = exact.map { existing in existing.filter(keys.contains) } ?? keys
    }

    func admits(_ key: Data) -> Bool {
        if let start {
            if key.lexicographicallyPrecedes(start.key) || (key == start.key && !start.isClosed) { return false }
        }
        if let end {
            if end.key.lexicographicallyPrecedes(key) || (key == end.key && !end.isClosed) { return false }
        }
        return true
    }

    var admittedKeys: [Data] {
        exact?.filter(admits) ?? []
    }

    var rangeJSON: [String: Any] {
        var range: [String: Any] = [:]
        if let start { range[start.isClosed ? "startKeyClosed" : "startKeyOpen"] = start.key.base64EncodedString() }
        if let end { range[end.isClosed ? "endKeyClosed" : "endKeyOpen"] = end.key.base64EncodedString() }
        return range
    }
}
