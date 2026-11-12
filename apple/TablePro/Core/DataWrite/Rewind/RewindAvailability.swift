//
//  RewindAvailability.swift
//  TablePro
//

import Combine
import Foundation

struct RewindAvailability: Equatable, Sendable {
    struct Target: Hashable, Sendable {
        let connectionId: UUID
        let database: String
        let schema: String?
        let table: String
    }

    let revision: Int
    let targets: Set<Target>
    let historyIds: Set<UUID>

    static let empty = RewindAvailability(revision: -1, targets: [], historyIds: [])
}

// Menu and toolbar validation is synchronous, so the main actor keeps the history actor's last answer.
@MainActor
final class RewindAvailabilityCache: ObservableObject {
    @Published private(set) var availability = RewindAvailability.empty

    nonisolated init(storage: QueryHistoryStorage) {
        // Weak, so the subscription never keeps the store alive: its deinit finishes the stream.
        Task { @MainActor [weak self, weak storage] in
            guard let updates = await storage?.rewindAvailabilityUpdates() else { return }
            for await next in updates {
                guard let self else { return }
                adopt(next)
            }
        }
    }

    func hasSnapshot(for target: RewindAvailability.Target) -> Bool {
        availability.targets.contains(target)
    }

    func hasSnapshot(forHistoryId historyId: UUID) -> Bool {
        availability.historyIds.contains(historyId)
    }

    // Readings can reach the main actor out of order, so only a newer revision replaces the current one.
    func adopt(_ next: RewindAvailability) {
        guard next.revision > availability.revision else { return }
        availability = next
    }
}
