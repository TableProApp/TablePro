import ActivityKit
import Foundation

enum QueryActivityStaleWindow {
    static let seconds: TimeInterval = 5 * 60
}

nonisolated struct QueryActivityAttributes: ActivityAttributes {
    enum Outcome: String, Codable, Hashable, Sendable {
        case running
        case completed
        case failed
        case stopped
        case interrupted
    }

    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var lastUpdatedAt: Date
        var endedAt: Date?
        var rowsStreamed: Int
        var outcome: Outcome

        init(
            startedAt: Date,
            lastUpdatedAt: Date? = nil,
            endedAt: Date? = nil,
            rowsStreamed: Int = 0,
            outcome: Outcome = .running
        ) {
            self.startedAt = startedAt
            self.lastUpdatedAt = lastUpdatedAt ?? startedAt
            self.endedAt = endedAt
            self.rowsStreamed = rowsStreamed
            self.outcome = outcome
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            startedAt = try container.decode(Date.self, forKey: .startedAt)
            lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) ?? startedAt
            endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
            rowsStreamed = try container.decodeIfPresent(Int.self, forKey: .rowsStreamed) ?? 0
            let stored = try container.decodeIfPresent(Outcome.self, forKey: .outcome)
            outcome = stored ?? (endedAt == nil ? .running : .completed)
        }

        var elapsedWhenLastAlive: TimeInterval {
            max(0, lastUpdatedAt.timeIntervalSince(startedAt))
        }

        func ended(as outcome: Outcome, at endedAt: Date) -> ContentState {
            ContentState(
                startedAt: startedAt,
                lastUpdatedAt: endedAt,
                endedAt: endedAt,
                rowsStreamed: rowsStreamed,
                outcome: outcome
            )
        }
    }

    let connectionId: UUID
    let connectionName: String
    let queryPreview: String
}
