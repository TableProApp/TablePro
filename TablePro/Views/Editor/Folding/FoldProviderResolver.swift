//
//  FoldProviderResolver.swift
//  TablePro
//

import CodeEditLanguages
import CodeEditSourceEditor
import TableProPluginKit

/// Chooses the fold provider for an editor's language.
///
/// Every editor in the app asks here rather than reaching for ``SQLLineFoldProvider`` itself, because the answer is
/// not always that provider. Returning `nil` leaves the editor on its own indentation-based provider, which is the
/// right answer for the languages TablePro does not parse: JSON, JavaScript and shell scripts all nest the way they
/// indent, and handing them a SQL scanner would fold on semicolons and parentheses that mean something else.
@MainActor
enum FoldProviderResolver {
    /// The provider for a connection, which knows both the language and the SQL dialect.
    static func provider(for databaseType: DatabaseType) -> LineFoldProvider? {
        provider(
            for: PluginManager.shared.editorLanguage(for: databaseType),
            dialect: SqlDialect.from(databaseTypeId: databaseType.rawValue)
        )
    }

    /// The provider for a listing whose language is known but whose dialect is not, such as a fenced code block.
    static func provider(for language: CodeLanguage) -> LineFoldProvider? {
        language.id == CodeLanguage.sql.id ? SQLLineFoldProvider() : nil
    }

    private static func provider(for language: EditorLanguage, dialect: SqlDialect) -> LineFoldProvider? {
        switch language {
        case .sql:
            return SQLLineFoldProvider(dialect: dialect)
        case .javascript, .bash, .custom:
            return nil
        }
    }
}
