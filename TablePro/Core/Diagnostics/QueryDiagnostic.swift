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

@MainActor
enum QueryDiagnosticsFactory {
    static func make(for databaseType: DatabaseType?) -> QueryDiagnosticsProducing {
        let dialect = databaseType ?? .mysql

        switch PluginManager.shared.editorLanguage(for: dialect) {
        case .javascript:
            return MongoDiagnosticsProducer()
        default:
            return SQLDiagnosticsProducer()
        }
    }
}
