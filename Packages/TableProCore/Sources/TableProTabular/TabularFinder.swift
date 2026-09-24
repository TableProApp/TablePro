import Foundation
import TableProTabularIO

public struct TabularFindQuery: Sendable, Equatable {
    public var text: String
    public var matchesCase: Bool
    public var matchesWholeWords: Bool
    public var isRegularExpression: Bool
    public var columns: [TabularColumnID]

    public init(
        text: String,
        matchesCase: Bool = false,
        matchesWholeWords: Bool = false,
        isRegularExpression: Bool = false,
        columns: [TabularColumnID]
    ) {
        self.text = text
        self.matchesCase = matchesCase
        self.matchesWholeWords = matchesWholeWords
        self.isRegularExpression = isRegularExpression
        self.columns = columns
    }
}

public struct TabularFindMatch: Sendable, Hashable {
    public let row: Int
    public let column: TabularColumnID

    public init(row: Int, column: TabularColumnID) {
        self.row = row
        self.column = column
    }
}

public struct TabularReplaceResult: Sendable, Equatable {
    public let values: [TabularColumnID: ColumnValues]
    public let changedCells: Int
    public let replacements: Int
}

public final class TabularFindMatcher: @unchecked Sendable {
    private let query: TabularFindQuery
    private let expression: NSRegularExpression
    private let literalNeedle: TabularNeedle?

    public init(_ query: TabularFindQuery) throws {
        self.query = query
        let body = query.isRegularExpression ? query.text : NSRegularExpression.escapedPattern(for: query.text)
        let pattern = query.matchesWholeWords ? "\\b(?:\(body))\\b" : body
        do {
            expression = try NSRegularExpression(pattern: pattern, options: query.matchesCase ? [] : [.caseInsensitive])
        } catch {
            throw TabularEditError.invalidPattern(query.text)
        }
        let usesLiteralSearch = !query.isRegularExpression && !query.matchesWholeWords
        literalNeedle = usesLiteralSearch ? TabularNeedle(query.text) : nil
    }

    public static func validate(_ query: TabularFindQuery) -> Bool {
        (try? TabularFindMatcher(query)) != nil
    }

    public func matches(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !query.text.isEmpty else { return false }
        if let literalNeedle {
            return TabularTextMatching.contains(bytes, literalNeedle, caseSensitive: query.matchesCase)
        }
        let text = TabularTextMatching.string(bytes) as NSString
        return expression.firstMatch(in: text as String, options: [], range: NSRange(location: 0, length: text.length)) != nil
    }

    public func replacing(in text: String, with template: String) -> (text: String, replacements: Int) {
        let source = text as NSString
        let range = NSRange(location: 0, length: source.length)
        let count = expression.numberOfMatches(in: text, options: [], range: range)
        guard count > 0 else { return (text, 0) }
        let effectiveTemplate = query.isRegularExpression ? template : NSRegularExpression.escapedTemplate(for: template)
        let replaced = expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: effectiveTemplate)
        return (replaced, count)
    }
}

public enum TabularFinder {
    public static func findAll(
        _ query: TabularFindQuery,
        rows: [Int],
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TabularFindMatch] {
        let matcher = try TabularFindMatcher(query)
        guard !query.text.isEmpty, !query.columns.isEmpty else { return [] }
        let columns = query.columns
        let chunks = try await TabularScanEngine.forEachChunk(of: 0..<rows.count, progress: progress) { chunk, counter in
            var found: [TabularFindMatch] = []
            var processed = 0
            var cancelled = false
            table.scan(columns: columns, logicalRows: rows[chunk]) { logicalRow, cells in
                for (slot, column) in columns.enumerated() where matcher.matches(cells.bytes[slot]) {
                    found.append(TabularFindMatch(row: logicalRow, column: column))
                }
                processed += 1
                if processed == TabularScanEngine.cancellationStride {
                    counter.add(processed)
                    processed = 0
                    if Task.isCancelled {
                        cancelled = true
                        return false
                    }
                }
                return true
            }
            counter.add(processed)
            if cancelled { throw CancellationError() }
            return found
        }
        return chunks.flatMap { $0 }
    }

    public static func replaceAll(
        _ query: TabularFindQuery,
        with template: String,
        rows: [Int],
        in table: TabularTable,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TabularReplaceResult {
        let matcher = try TabularFindMatcher(query)
        var values: [TabularColumnID: ColumnValues] = [:]
        var changedCells = 0
        let counter = ReplacementCounter()
        for (index, column) in query.columns.enumerated() {
            let share = 1 / Double(max(1, query.columns.count))
            let result = try await TabularColumnRewrite.rewrite(
                column: column,
                rows: rows,
                in: table,
                progress: { progress(Double(index) * share + $0 * share) }
            ) { kind, bytes in
                guard !kind.isNullLike, matcher.matches(bytes) else { return nil }
                let replaced = matcher.replacing(in: TabularTextMatching.string(bytes), with: template)
                guard replaced.replacements > 0 else { return nil }
                counter.add(replaced.replacements)
                return TabularCell(kind: .text, text: replaced.text)
            }
            guard result.changedCells > 0 else { continue }
            values[column] = result.values
            changedCells += result.changedCells
        }
        return TabularReplaceResult(values: values, changedCells: changedCells, replacements: counter.total)
    }
}

final class ReplacementCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ count: Int) {
        lock.lock()
        value += count
        lock.unlock()
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
