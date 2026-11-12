import Foundation

// Answers `SQLStatementScanner.locatedStatementAtCursor` for a document that changes a little at a time: the scan
// resumes from the last recorded statement boundary before the caret instead of from the top.
public struct SQLStatementCursorIndex: Sendable {
    public static let defaultCheckpointSpacing = 4_096

    public let grammar: SQLLexicalGrammar
    public private(set) var unitsScanned = 0

    private let checkpointSpacing: Int
    // In offset order, and so in `decidedThrough` order too.
    private var checkpoints: [SQLStatementScanner.Checkpoint] = []

    public init(grammar: SQLLexicalGrammar, checkpointSpacing: Int = SQLStatementCursorIndex.defaultCheckpointSpacing) {
        self.grammar = grammar
        self.checkpointSpacing = max(1, checkpointSpacing)
    }

    public var checkpointCount: Int {
        checkpoints.count
    }

    // Call before the next lookup whenever the text changed at or after `location`.
    public mutating func textDidChange(at location: Int) {
        while let last = checkpoints.last, last.decidedThrough >= location {
            checkpoints.removeLast()
        }
    }

    public mutating func statementAtCursor(_ cursorPosition: Int, in text: String) -> SQLStatementScanner.LocatedStatement {
        let length = (text as NSString).length
        let cursor = min(max(0, cursorPosition), length)
        let resume = lastCheckpoint(before: cursor)
        let start = resume?.offset ?? 0
        let spacing = checkpointSpacing

        var lastRecorded = checkpoints.last?.offset ?? 0
        var recorded: [SQLStatementScanner.Checkpoint] = []
        var result = SQLStatementScanner.LocatedStatement(sql: "", offset: 0, hasContent: false)
        SQLStatementScanner.scan(
            sql: text,
            cursorPosition: cursor,
            grammar: grammar,
            resumingAt: resume,
            onCheckpoint: { checkpoint in
                guard checkpoint.offset - lastRecorded >= spacing else { return }
                recorded.append(checkpoint)
                lastRecorded = checkpoint.offset
            },
            onStatement: { statement in
                result = statement
                return false
            }
        )
        checkpoints.append(contentsOf: recorded)
        unitsScanned += max(cursor, NSMaxRange(result.range)) - start
        return result
    }

    private func lastCheckpoint(before offset: Int) -> SQLStatementScanner.Checkpoint? {
        var low = 0
        var high = checkpoints.count
        while low < high {
            let middle = (low + high) / 2
            if checkpoints[middle].offset < offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? checkpoints[low - 1] : nil
    }
}
