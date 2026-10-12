import Foundation

/// The screens waiting on one connect attempt.
///
/// An attempt belongs to the screens awaiting it: the last one to leave abandons it, so a reopened
/// connection never joins an attempt the user walked away from, and a screen replaced by another
/// never cancels an attempt the new one is still waiting for. Each joiner leaves under its own id,
/// so a caller that is cancelled and later resumes cannot leave twice and make the count lie.
nonisolated struct AttemptJoiners {
    private var ids: Set<UUID> = []

    var isEmpty: Bool { ids.isEmpty }

    mutating func join() -> UUID {
        let id = UUID()
        ids.insert(id)
        return id
    }

    /// True when this joiner was still waiting and was the last one.
    mutating func leave(_ id: UUID) -> Bool {
        guard ids.remove(id) != nil else { return false }
        return ids.isEmpty
    }
}
