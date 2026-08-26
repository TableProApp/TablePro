import Foundation
import TableProPluginKit

@MainActor
final class SQLCompletionService: QueryCompletionService {
    private let engine: CompletionEngine
    private var lastContext = SQLContext.unanalyzed

    private static let windowRadius = 5_000

    init(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil
    ) {
        let dialect = profile?.resolvedDialect
            ?? databaseType.flatMap { PluginManager.shared.sqlDialect(for: $0) }
        let statementCompletions = profile?.statementCompletions
            ?? databaseType.flatMap { PluginManager.shared.statementCompletions(for: $0) }
            ?? []
        self.engine = CompletionEngine(
            schemaProvider: schemaProvider,
            databaseType: databaseType,
            dialect: dialect,
            statementCompletions: statementCompletions
        )
    }

    var triggerCharacters: Set<String> { [".", " ", ":", "(", ","] }

    /// Seeding starts a session the analyzer has not seen, so the context a previous session
    /// left behind stops describing anything. Ranking a seeded session against it would score
    /// the new prefix under the old clause.
    func seedItems() -> [SQLCompletionItem] {
        lastContext = .unanalyzed
        let items = engine.keywordCompletions() + engine.allFavoriteItems()
        return Array(items.prefix(engine.provider.seedPoolLimit))
    }

    func prepare() async {
        await engine.retrySchemaIfNeeded()
    }

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        engine.updateFavoriteKeywords(keywords)
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        SQLTokenBoundary.segmentStart(in: text, endingAt: offset)
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        engine.provider.filterRankAndLimit(items, prefix: prefix, context: lastContext)
    }

    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession? {
        guard !suppressesAfterStatementBreak(in: text, at: offset) else { return nil }

        let windowStart = max(0, offset - Self.windowRadius)
        let windowEnd = min(text.length, offset + Self.windowRadius)
        let window = text.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart))

        guard let context = await engine.getCompletions(text: window, cursorPosition: offset - windowStart) else {
            return nil
        }
        guard !isSuppressedEmptyPrefix(context.sqlContext, isManualTrigger: isManualTrigger) else { return nil }

        lastContext = context.sqlContext
        return QueryCompletionSession(
            items: context.items,
            candidates: context.candidates,
            replacementRange: NSRange(
                location: context.replacementRange.location + windowStart,
                length: context.replacementRange.length
            )
        )
    }

    private func suppressesAfterStatementBreak(in text: NSString, at offset: Int) -> Bool {
        guard offset > 0, offset - 1 < text.length else { return false }

        let previous = text.character(at: offset - 1)
        let semicolon = UInt16(UnicodeScalar(";").value)
        let newline = UInt16(UnicodeScalar("\n").value)
        guard previous == semicolon || previous == newline else { return false }
        guard offset < text.length else { return true }

        return text.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSuppressedEmptyPrefix(_ context: SQLContext, isManualTrigger: Bool) -> Bool {
        guard !isManualTrigger, context.prefix.isEmpty, context.dotPrefix == nil else { return false }

        switch context.clauseType {
        case .from, .join, .into, .set, .insertColumns, .on,
             .alterTableColumn, .returning, .using, .dropObject, .createIndex:
            return false
        case .select where !context.isAfterComma:
            return false
        default:
            return true
        }
    }
}
