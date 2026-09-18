import Foundation

/// What a query's duration was actually spent on.
///
/// A single elapsed number cannot answer "was the query slow, or was the link slow", which is the
/// question a user asks of a remote database or a tunnelled one. `total` is that elapsed number and
/// stays what it always was. The other two are optional because most engines can only supply one of
/// them and some can supply neither, and a fabricated figure is worse than an absent one.
///
/// `firstRow` is client-measured and therefore carries one network round trip. `server` is the
/// engine's own report and carries none, so it wins wherever a protocol already sends it.
public struct PluginQueryTiming: Codable, Sendable, Hashable {
    /// Send to last row decoded.
    public let total: TimeInterval

    /// Send to the first row, or to the completion of a statement that returns none. Nil when the
    /// driver buffers the whole result before it can see a row.
    public let firstRow: TimeInterval?

    /// Execution time as the engine itself reported it. Nil when the protocol does not carry one.
    public let server: TimeInterval?

    public init(total: TimeInterval, firstRow: TimeInterval? = nil, server: TimeInterval? = nil) {
        self.total = total
        self.firstRow = firstRow
        self.server = server
    }

    /// The best available estimate of the time the database spent, as opposed to the wire.
    ///
    /// Falling back to `total` keeps the quantity defined for every driver, so a ranking built on it
    /// never has to drop the rows that could not measure a split.
    public var databaseTime: TimeInterval {
        server ?? firstRow ?? total
    }

    /// The part of the elapsed time spent moving rows, when the split is known.
    public var transfer: TimeInterval? {
        guard let firstRow else { return nil }
        return max(0, total - firstRow)
    }

    /// Whether there is anything to show beyond the elapsed number.
    public var hasBreakdown: Bool {
        firstRow != nil || server != nil
    }
}
