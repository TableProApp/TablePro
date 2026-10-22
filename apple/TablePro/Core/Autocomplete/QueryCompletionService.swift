import Foundation
import TableProAutocomplete
import TableProPluginKit

struct QueryCompletionSession {
    let items: [SQLCompletionItem]
    // Wider than `items`, so a longer prefix can promote a candidate the opening prefix ranked out of view.
    let candidates: [SQLCompletionItem]
    let replacementRange: NSRange
    // In document offsets. The re-rank and the accept read it, since a local walk back stops at a space in the name.
    var quotedName: SQLQuotedName?
}

@MainActor
protocol QueryCompletionService: AnyObject {
    var triggerCharacters: Set<String> { get }

    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession?
    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem]
    func tokenStart(in text: NSString, endingAt offset: Int) -> Int
    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)])
}

@MainActor
enum QueryCompletionServiceFactory {
    static func make(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil,
        connectionId: UUID? = nil
    ) -> QueryCompletionService {
        let language = databaseType.map { PluginManager.shared.editorLanguage(for: $0) } ?? .sql

        switch language {
        case .javascript:
            return MongoCompletionService(schemaProvider: schemaProvider, databaseType: databaseType)
        default:
            return SQLCompletionService(
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                profile: profile,
                identifierCase: { SQLIdentifierCase.stored(for: connectionId) }
            )
        }
    }
}
