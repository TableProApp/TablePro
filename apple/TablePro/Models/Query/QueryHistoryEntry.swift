import Foundation
import TableProPluginKit
import TableProUtilities

struct QueryHistoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let query: String
    let connectionId: UUID
    let databaseName: String
    let databaseType: DatabaseType
    let schemaName: String?
    let source: QueryHistorySource
    let statementType: QueryHistoryStatementType
    let executedAt: Date
    let executionTime: TimeInterval
    let rowCount: Int
    let wasSuccessful: Bool
    let errorMessage: String?

    /// Client-measured time to the first row, when the driver could see one.
    let firstRowTime: TimeInterval?

    /// Execution time as the engine reported it, when its protocol carries one.
    let serverTime: TimeInterval?

    init(
        id: UUID = UUID(),
        query: String,
        connectionId: UUID,
        databaseName: String,
        databaseType: DatabaseType,
        schemaName: String? = nil,
        source: QueryHistorySource,
        statementType: QueryHistoryStatementType? = nil,
        executedAt: Date = Date(),
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil,
        firstRowTime: TimeInterval? = nil,
        serverTime: TimeInterval? = nil
    ) {
        self.id = id
        self.query = query
        self.connectionId = connectionId
        self.databaseName = databaseName
        self.databaseType = databaseType
        self.schemaName = schemaName
        self.source = source
        self.statementType = statementType ?? QueryHistoryStatementType.classify(query, grammar: databaseType.lexicalGrammar)
        self.executedAt = executedAt
        self.executionTime = executionTime
        self.rowCount = rowCount
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
        self.firstRowTime = firstRowTime
        self.serverTime = serverTime
    }

    var timing: PluginQueryTiming {
        PluginQueryTiming(total: executionTime, firstRow: firstRowTime, server: serverTime)
    }

    /// What the database itself spent, as opposed to the wire. This is what the insights panels
    /// rank on, so a query that is only slow to transfer stops reading as a slow query.
    var databaseTime: TimeInterval { timing.databaseTime }

    var formattedDatabaseTime: String {
        QueryDurationFormatter.string(from: databaseTime)
    }

    var cursor: QueryHistoryCursor {
        QueryHistoryCursor(executedAt: executedAt, id: id)
    }

    var hasKnownRowCount: Bool { rowCount >= 0 }

    var hasMeasuredDuration: Bool { executionTime > 0 }

    /// A file-backed database names itself with its whole path, which tells the reader nothing a
    /// row has room for. The file name is the part that identifies it.
    var databaseDisplayName: String {
        guard databaseName.contains("/") else { return databaseName }
        let fileName = (databaseName as NSString).lastPathComponent
        return fileName.isEmpty ? databaseName : fileName
    }

    var formattedExecutionTime: String {
        QueryDurationFormatter.string(from: executionTime)
    }

    var formattedRowCount: String {
        guard hasKnownRowCount else { return "–" }
        return String(
            format: String(localized: "%lld rows", comment: "Row count in query history, %lld is the number of rows"),
            rowCount
        )
    }

    // Reads only the ends of the query: the Quick Switcher builds this for every history item it lists.
    var queryPreview: String {
        let trimmable = CharacterSet.whitespacesAndNewlines
        let scalars = query.unicodeScalars
        guard let first = scalars.firstIndex(where: { !trimmable.contains($0) }),
              let last = scalars.lastIndex(where: { !trimmable.contains($0) }) else {
            return ";"
        }
        var head = PreviewHead(limit: 100)
        for scalar in scalars[first...last] {
            head.append(scalar)
            if head.isComplete { return head.preview }
        }
        var trimmed = head.text
        if !trimmed.hasSuffix(";") {
            trimmed += ";"
        }
        return PreviewHead.shortened(trimmed, to: head.limit)
    }

    // Stops reading once the cut is known: a history row builds this every time it renders.
    var singleLinePreview: String {
        let newlines = CharacterSet.newlines
        let whitespaces = CharacterSet.whitespaces
        let scalars = query.unicodeScalars
        var head = PreviewHead(limit: 160)
        var lineHasText = false
        var gapStart: String.UnicodeScalarView.Index?
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if newlines.contains(scalar) {
                lineHasText = false
                gapStart = nil
            } else if whitespaces.contains(scalar) {
                if lineHasText && gapStart == nil {
                    gapStart = index
                }
            } else {
                if !lineHasText {
                    lineHasText = true
                    if !head.text.isEmpty {
                        head.append(" ")
                    }
                } else if let start = gapStart {
                    gapStart = nil
                    for gapScalar in scalars[start..<index] {
                        head.append(gapScalar)
                    }
                }
                head.append(scalar)
                if head.isComplete { return head.preview }
            }
            scalars.formIndex(after: &index)
        }
        return head.preview
    }
}

// Appending to a string can change only its last Character, so once the head holds more than `limit` Characters its
// first `limit` are those of the whole preview, and the rest of the query cannot change the result.
private struct PreviewHead {
    let limit: Int
    private(set) var text = ""
    private(set) var isComplete = false
    private var scalarCount = 0
    private var nextCount: Int

    init(limit: Int) {
        self.limit = limit
        nextCount = limit + 1
    }

    var preview: String {
        Self.shortened(text, to: limit)
    }

    mutating func append(_ scalar: Unicode.Scalar) {
        text.unicodeScalars.append(scalar)
        scalarCount += 1
        // Counting Characters only when the scalar count doubles keeps the work linear.
        guard scalarCount >= nextCount else { return }
        nextCount = scalarCount * 2
        isComplete = text.count > limit
    }

    // Tests the UTF-16 length but cuts at a Character count, as the previews always have.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard (text as NSString).length > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
