import Foundation
import os

public enum StreamElement: Sendable {
    case columns([ColumnInfo])
    case row(Row)
    case rowsAffected(Int)
    case statusMessage(String)
    case truncated(reason: TruncationReason)
}

public enum TruncationReason: Sendable {
    case rowCap(Int)
    case memoryPressure
    case cancelled
    case driverLimit(String)
}

public struct StreamOptions: Sendable {
    public let textTruncationBytes: Int
    public let inlineBinary: Bool
    public let maxRows: Int
    public let lazyContext: LazyContext?
    // Long text with no ref stays whole while this admits it; nil cuts every long value.
    public var textBudget: TextBudget?
    // Safe Mode is Read-Only. A driver whose `enforcesReadOnlyMode` is true runs the statement in the engine's
    // read-only mode or refuses it; any other driver runs it as it is.
    public var enforcesReadOnly: Bool

    public init(
        textTruncationBytes: Int = Cell.previewByteLimit,
        inlineBinary: Bool = false,
        maxRows: Int = 100_000,
        lazyContext: LazyContext? = nil,
        textBudget: TextBudget? = nil,
        enforcesReadOnly: Bool = false
    ) {
        self.textTruncationBytes = textTruncationBytes
        self.inlineBinary = inlineBinary
        self.maxRows = maxRows
        self.lazyContext = lazyContext
        self.textBudget = textBudget
        self.enforcesReadOnly = enforcesReadOnly
    }

    public static let `default` = StreamOptions()
}

// Shared by every cell of one request, and read from whatever thread the driver decodes on.
public final class TextBudget: Sendable {
    private struct State: Sendable {
        var remaining: Int
        var refused = false
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(bytes: Int) {
        state = OSAllocatedUnfairLock(initialState: State(remaining: max(0, bytes)))
    }

    public func admit(_ bytes: Int) -> Bool {
        state.withLock { state in
            guard bytes <= state.remaining else {
                state.refused = true
                return false
            }
            state.remaining -= bytes
            return true
        }
    }

    public var hasRefused: Bool {
        state.withLock { $0.refused }
    }
}

public struct LazyContext: Sendable {
    public let table: String
    public let primaryKeyColumns: [String]

    public init(table: String, primaryKeyColumns: [String]) {
        self.table = table
        self.primaryKeyColumns = primaryKeyColumns
    }
}
