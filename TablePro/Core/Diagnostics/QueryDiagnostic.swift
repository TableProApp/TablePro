import Foundation
import TableProPluginKit

struct QueryDiagnostic: Equatable, Identifiable {
    enum Severity: String {
        case error
        case warning
    }

    let id: UUID
    let range: NSRange
    let message: String
    let severity: Severity

    init(range: NSRange, message: String, severity: Severity = .error) {
        self.id = UUID()
        self.range = range
        self.message = message
        self.severity = severity
    }

    static func == (lhs: QueryDiagnostic, rhs: QueryDiagnostic) -> Bool {
        lhs.range == rhs.range && lhs.message == rhs.message && lhs.severity == rhs.severity
    }
}

protocol QueryDiagnosticsProducing: Sendable {
    func diagnostics(for text: String) -> [QueryDiagnostic]
}

enum QueryDiagnosticsLimits {
    static let maximumDocumentLength = 100_000
}

struct CombinedQueryDiagnosticsProducer: QueryDiagnosticsProducing {
    let producers: [QueryDiagnosticsProducing]

    func diagnostics(for text: String) -> [QueryDiagnostic] {
        producers.flatMap { $0.diagnostics(for: text) }
    }
}

@MainActor
enum QueryDiagnosticsFactory {
    static func make(for databaseType: DatabaseType?) -> QueryDiagnosticsProducing {
        let resolvedType = databaseType ?? .mysql

        // Highlighting as JavaScript does not make the language JavaScript: Elasticsearch, Typesense
        // and Weaviate do it for their JSON bodies. Only a MongoDB script is a program the parser can check.
        if QueryStatementModel.forDatabaseType(resolvedType) == .javascript {
            return MongoDiagnosticsProducer()
        }

        switch PluginManager.shared.editorLanguage(for: resolvedType) {
        case .javascript:
            return ConsoleRequestDiagnosticsProducer()
        case .sql:
            return CombinedQueryDiagnosticsProducer(producers: [
                SQLDiagnosticsProducer(),
                SQLConfusableCharacterDiagnosticsProducer(grammar: resolvedType.lexicalGrammar)
            ])
        case .bash:
            // A command line's arguments are plain text, so `SET smile :)` holds a bracket that closes
            // nothing and is still a valid command. There is no structure to check.
            return CombinedQueryDiagnosticsProducer(producers: [])
        case .custom:
            return SQLDiagnosticsProducer()
        }
    }
}
