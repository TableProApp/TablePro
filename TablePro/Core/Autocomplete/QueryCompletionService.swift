import Foundation
import TableProPluginKit

struct QueryCompletionSession {
    let items: [SQLCompletionItem]
    let replacementRange: NSRange
}

@MainActor
protocol QueryCompletionService: AnyObject {
    var triggerCharacters: Set<String> { get }

    func seedItems() -> [SQLCompletionItem]
    func prepare() async
    func completions(in text: NSString, at offset: Int, isManualTrigger: Bool) async -> QueryCompletionSession?
    func filter(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem]
    func rank(_ items: [SQLCompletionItem], prefix: String) -> [SQLCompletionItem]
    func tokenStart(in text: NSString, endingAt offset: Int) -> Int
    func updateFavoriteKeywords(_ keywords: [String: (name: String, query: String)])
}

@MainActor
enum QueryCompletionServiceFactory {
    static func make(
        schemaProvider: SQLSchemaProvider?,
        databaseType: DatabaseType?,
        profile: QueryCompletionProfile? = nil
    ) -> QueryCompletionService {
        let language = databaseType.map { PluginManager.shared.editorLanguage(for: $0) } ?? .sql

        switch language {
        case .javascript:
            return MongoCompletionService(schemaProvider: schemaProvider, databaseType: databaseType)
        default:
            return SQLCompletionService(
                schemaProvider: schemaProvider,
                databaseType: databaseType,
                profile: profile
            )
        }
    }
}
