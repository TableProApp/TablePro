//
//  CompareSyncEngineFamily.swift
//  TablePro
//
//  Which pairs of database types may generate a structure sync script.
//  Column data types are driver-native strings, so generating DDL for one engine
//  from another engine's metadata is unsound. Comparison stays available across
//  engines as an informational read; only script generation is gated.
//

import Foundation
import TableProPluginKit

internal enum CompareSyncEngineFamily {
    /// A sampled column list is not a schema. A field the source's sample missed reads as one the
    /// target holds and the source does not, and a script would remove it from every document of
    /// the target.
    internal static func canGenerateStructureScript(
        from source: DatabaseType,
        to target: DatabaseType,
        sourceSession: PluginSessionLexicalState? = nil,
        targetSession: PluginSessionLexicalState? = nil
    ) -> Bool {
        guard !source.columnsAreSampled, !target.columnsAreSampled else { return false }
        let sourceFamily = SQLTypeFamily.of(source, session: sourceSession)
        guard sourceFamily == SQLTypeFamily.of(target, session: targetSession) else { return false }
        guard source != target else { return true }
        return sameFamily(source, target)
    }

    internal static func sameFamily(_ lhs: DatabaseType, _ rhs: DatabaseType) -> Bool {
        guard lhs != rhs else { return true }
        let key = [lhs.rawValue, rhs.rawValue].sorted().joined(separator: "\u{1F}")
        return compatiblePairKeys.contains(key)
    }

    private static let compatiblePairKeys: Set<String> = {
        let pairs: [[DatabaseType]] = [
            [.mysql, .mariadb],
            [.postgresql, .kingbasees]
        ]
        return Set(pairs.map { $0.map { $0.rawValue }.sorted().joined(separator: "\u{1F}") })
    }()

    internal static func structureScriptRefusal(
        from source: DatabaseType,
        to target: DatabaseType,
        sourceSession: PluginSessionLexicalState? = nil,
        targetSession: PluginSessionLexicalState? = nil
    ) -> String {
        if let sampled = [source, target].first(where: \.columnsAreSampled) {
            return String(
                format: String(localized: "%@ lists a collection's fields from a sample of its documents, so structures can be compared but no script is generated."),
                sampled.rawValue
            )
        }
        if let moded = [(source, sourceSession), (target, targetSession)]
            .first(where: { SQLTypeFamily.leavesFamily($0.0, session: $0.1) }) {
            return String(
                format: String(localized: "%@ runs in a compatibility mode with column types of its own, so structures can be compared but no script is generated."),
                moded.0.rawValue
            )
        }
        return String(
            format: String(localized: "Structure sync needs matching database types. %@ and %@ can be compared, but no script is generated."),
            source.rawValue, target.rawValue
        )
    }

    internal static func crossEngineDataWarning(from source: DatabaseType, to target: DatabaseType) -> String? {
        guard source != target else { return nil }
        return String(
            format: String(localized: "Syncing data from %@ to %@. Value formatting can differ between engines; review the script before applying."),
            source.rawValue, target.rawValue
        )
    }
}
