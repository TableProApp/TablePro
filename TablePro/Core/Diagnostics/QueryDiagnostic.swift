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

        switch PluginManager.shared.editorLanguage(for: resolvedType) {
        case .javascript:
            return MongoDiagnosticsProducer()
        case .sql:
            return CombinedQueryDiagnosticsProducer(producers: [
                SQLDiagnosticsProducer(),
                SQLConfusableCharacterDiagnosticsProducer(rules: SQLLexicalRules(
                    databaseType: resolvedType,
                    descriptor: PluginManager.shared.sqlDialect(for: resolvedType)
                ))
            ])
        default:
            return SQLDiagnosticsProducer()
        }
    }
}
