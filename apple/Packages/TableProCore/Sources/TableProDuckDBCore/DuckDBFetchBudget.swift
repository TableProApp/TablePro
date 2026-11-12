import Foundation

// Counts the rows of a result read chunk by chunk against a row limit. The limit is exceeded only once a row past it
// has been seen, so a result of exactly `limit` rows is whole.
public struct DuckDBFetchBudget: Sendable, Equatable {
    public let limit: Int
    public private(set) var kept = 0
    public private(set) var isExceeded = false

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    public mutating func take(_ count: Int) -> Int {
        let room = limit - kept
        guard count > room else {
            kept += max(0, count)
            return max(0, count)
        }
        kept = limit
        isExceeded = true
        return room
    }
}

// What happens to the rest of a result the reader stops in the middle of.
public enum DuckDBUnreadRows: Sendable, Equatable {
    case drain
    case abandon
    case abandonWhenIdle

    // Dropping an unfinished statement that may write aborts the transaction it runs in, so only a session known to
    // hold none drops one.
    public func abandons(sessionIsIdle: () -> Bool) -> Bool {
        switch self {
        case .drain: false
        case .abandon: true
        case .abandonWhenIdle: sessionIsIdle()
        }
    }
}

// The session settings that change how DuckDB spells a value as text, which a second connection rendering the first
// one's rows has to share.
public enum DuckDBRenderSettings {
    public static let names = ["TimeZone", "Calendar"]

    public static let readQuery =
        "SELECT name, value FROM duckdb_settings() WHERE name IN ('TimeZone', 'Calendar')"

    public static func assignments(from current: [String: String], to wanted: [String: String]) -> [String] {
        names.compactMap { name in
            guard let value = wanted[name], current[name] != value else { return nil }
            return "SET \(name) = '\(value.replacingOccurrences(of: "'", with: "''", options: .literal))'"
        }
    }
}

// Hands a row batch to a stream whose buffer is bounded. A buffering policy alone drops what does not fit, so the
// producer keeps the refused batch and offers it again once the consumer has read one.
public enum DuckDBBoundedStream {
    public static let bufferedBatches = 64

    // Returns false when the stream has ended and the producer should stop.
    public static func deliver<Element: Sendable>(
        _ element: Element,
        to continuation: AsyncThrowingStream<Element, Error>.Continuation,
        pause: () -> Void = { _ = usleep(2_000) }
    ) -> Bool {
        var pending = element
        while true {
            switch continuation.yield(pending) {
            case .enqueued:
                return true
            case .dropped(let refused):
                pending = refused
                pause()
            case .terminated:
                return false
            @unknown default:
                return false
            }
        }
    }
}
