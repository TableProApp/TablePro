//
//  FoldProviderResolver.swift
//  TablePro
//

import CodeEditSourceEditor
import TableProPluginKit

/// Chooses the fold provider for an editor's language.
///
/// Returning `nil` leaves the editor on its own indentation-based provider, which is the right answer for the
/// languages TablePro does not parse: JSON, JavaScript and shell scripts all nest the way they indent.
@MainActor
enum FoldProviderResolver {
    static func provider(for databaseType: DatabaseType) -> LineFoldProvider? {
        provider(
            for: PluginManager.shared.editorLanguage(for: databaseType),
            dialect: SqlDialect.from(databaseTypeId: databaseType.rawValue)
        )
    }

    static func provider(for language: EditorLanguage, dialect: SqlDialect) -> LineFoldProvider? {
        switch language {
        case .sql:
            return SQLLineFoldProvider(dialect: dialect)
        case .javascript, .bash, .custom:
            return nil
        }
    }
}
