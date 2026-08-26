import Foundation
import TableProPluginKit

@MainActor
final class MongoCompletionService: QueryCompletionService {
    private let schemaProvider: SQLSchemaProvider?
    private var favoriteKeywords: [String: (name: String, query: String)] = [:]

    private static let windowRadius = 5_000

    /// How many candidates a session may keep for re-ranking as the prefix grows. Every position's
    /// vocabulary is well under this except a collection's sampled field paths, which a wide
    /// document schema can run into the thousands; those sessions prefer what the popup showed,
    /// and the cap holds either way because filtering an empty opening prefix returns everything.
    private static let sessionPoolLimit = 400

    init(schemaProvider: SQLSchemaProvider?, databaseType: DatabaseType?) {
        self.schemaProvider = schemaProvider
        _ = databaseType
    }

    var triggerCharacters: Set<String> { [".", "$", "{", "[", "\"", "'", ":", " "] }

    func seedItems() -> [SQLCompletionItem] {
        MongoVocabulary.shellCommands.map { SQLCompletionItem.keyword($0.name, documentation: $0.detail) }
    }

    func prepare() async {}

    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)]) {
        favoriteKeywords = keywords
    }

    func tokenStart(in text: NSString, endingAt offset: Int) -> Int {
        MongoContextAnalyzer.prefixRange(in: text, endingAt: offset).location
    }

    private func filter(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        guard !prefix.isEmpty else { return items }
        let needle = prefix.lowercased()
        return items.filter { $0.filterText.hasPrefix(needle) || $0.filterText.contains(needle) }
            .sorted { lhs, rhs in
                let lhsComplete = lhs.filterText == needle
                let rhsComplete = rhs.filterText == needle
                if lhsComplete != rhsComplete { return lhsComplete }
                let lhsAnchored = lhs.filterText.hasPrefix(needle)
                let rhsAnchored = rhs.filterText.hasPrefix(needle)
                if lhsAnchored != rhsAnchored { return lhsAnchored }
                if lhs.sortPriority != rhs.sortPriority { return lhs.sortPriority < rhs.sortPriority }
                return lhs.label < rhs.label
            }
    }

    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem] {
        filter(items, prefix: prefix)
    }

    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession? {
        let windowStart = max(0, offset - Self.windowRadius)
        let windowEnd = min(text.length, offset + Self.windowRadius)
        let window = text.substring(with: NSRange(location: windowStart, length: windowEnd - windowStart)) as NSString
        let context = MongoContextAnalyzer.analyze(text: window, cursor: offset - windowStart)

        guard context.position != .suppressed else { return nil }
        guard isManualTrigger || !context.prefix.isEmpty || opensBrowsableList(context.position) else { return nil }

        let items = await items(for: context.position)
        guard !items.isEmpty else { return nil }

        let shown = filter(items, prefix: context.prefix)
        let pool = items.count <= Self.sessionPoolLimit ? items : shown

        return QueryCompletionSession(
            items: shown,
            candidates: Array(pool.prefix(Self.sessionPoolLimit)),
            replacementRange: NSRange(
                location: context.prefixRange.location + windowStart,
                length: context.prefixRange.length
            )
        )
    }

    private func opensBrowsableList(_ position: MongoCompletionPosition) -> Bool {
        switch position {
        case .databaseMember, .collectionMethod, .pipelineStage, .updatePipelineStage:
            return true
        default:
            return false
        }
    }

    private func items(for position: MongoCompletionPosition) async -> [SQLCompletionItem] {
        switch position {
        case .suppressed:
            return []
        case .statementStart:
            return seedItems() + favoriteItems() + [SQLCompletionItem.keyword("db", documentation: "Current database")]
        case .databaseMember:
            return await collectionItems() + methodItems(MongoVocabulary.databaseMethods)
        case .collectionMethod:
            return methodItems(MongoVocabulary.collectionMethods)
        case .filterDocument(let collection):
            return await fieldItems(for: collection) + operatorItems(MongoVocabulary.queryOperators)
        case .projectionDocument(let collection):
            return await fieldItems(for: collection) + operatorItems(MongoVocabulary.projectionOperators)
        case .plainDocument(let collection):
            return await fieldItems(for: collection) + constructorItems()
        case .updateDocument:
            return operatorItems(MongoVocabulary.updateOperators)
        case .updatePipelineStage:
            return stageItems(MongoVocabulary.updatePipelineStages)
        case .pipelineStage:
            return stageItems(MongoVocabulary.pipelineStages)
        case .stageExpression(let collection):
            return operatorItems(MongoVocabulary.expressionOperators)
                + operatorItems(MongoVocabulary.accumulators)
                + variableItems()
                + (await fieldPathItems(for: collection))
        }
    }

    private func favoriteItems() -> [SQLCompletionItem] {
        favoriteKeywords.map { SQLCompletionItem.favorite(keyword: $0.key, name: $0.value.name, query: $0.value.query) }
    }

    private func methodItems(_ methods: [(name: String, detail: String)]) -> [SQLCompletionItem] {
        methods.map { SQLCompletionItem.function($0.name, signature: "()", documentation: $0.detail) }
    }

    private func operatorItems(_ operators: [(name: String, detail: String)]) -> [SQLCompletionItem] {
        operators.map { SQLCompletionItem.operator($0.name, documentation: $0.detail) }
    }

    private func stageItems(_ stages: [(name: String, detail: String)]) -> [SQLCompletionItem] {
        stages.map { SQLCompletionItem.keyword($0.name, documentation: $0.detail) }
    }

    private func variableItems() -> [SQLCompletionItem] {
        MongoVocabulary.systemVariables.map { SQLCompletionItem.keyword($0.name, documentation: $0.detail) }
    }

    private func constructorItems() -> [SQLCompletionItem] {
        MongoVocabulary.bsonConstructors.map {
            SQLCompletionItem.function($0.name, signature: "()", documentation: $0.detail)
        }
    }

    private func collectionItems() async -> [SQLCompletionItem] {
        guard let schemaProvider else { return [] }
        return await schemaProvider.tableCompletionItems()
    }

    private func fieldItems(for collection: String?) async -> [SQLCompletionItem] {
        guard let schemaProvider, let collection else { return [] }

        let paths = await schemaProvider.fieldPaths(for: collection)
        guard !paths.isEmpty else {
            return await schemaProvider.columnCompletionItems(for: collection)
        }

        return paths.map { path in
            var item = SQLCompletionItem(
                label: path.path,
                kind: .column,
                insertText: path.path,
                detail: path.typeName
            )
            item.sortPriority = SQLCompletionKind.column.basePriority + path.depth
            return item
        }
    }

    private func fieldPathItems(for collection: String?) async -> [SQLCompletionItem] {
        await fieldItems(for: collection).map { item in
            SQLCompletionItem(
                label: "$\(item.label)",
                kind: .column,
                insertText: "$\(item.label)",
                detail: item.detail,
                documentation: item.documentation
            )
        }
    }
}
