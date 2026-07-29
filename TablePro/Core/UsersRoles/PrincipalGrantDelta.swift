import Foundation
import TableProPluginKit

struct PrincipalGrantDelta: Equatable {
    var added: Set<PrincipalGrantKey> = []
    var removed: Set<PrincipalGrantKey> = []

    var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    var count: Int { added.count + removed.count }

    mutating func stage(_ key: PrincipalGrantKey, granted: Bool, baselineHasKey: Bool) {
        guard granted != baselineHasKey else {
            added.remove(key)
            removed.remove(key)
            return
        }
        if granted {
            removed.remove(key)
            added.insert(key)
        } else {
            added.remove(key)
            removed.insert(key)
        }
    }

    func resolves(_ key: PrincipalGrantKey, baselineHasKey: Bool) -> Bool {
        if added.contains(key) { return true }
        if removed.contains(key) { return false }
        return baselineHasKey
    }

    mutating func rebase(onto baseline: Set<PrincipalGrantKey>) {
        added = added.filter { !baseline.contains($0) }
        removed = removed.filter { baseline.contains($0) }
    }
}
