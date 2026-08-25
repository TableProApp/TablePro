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

internal enum CompareSyncEngineFamily {
    internal static func canGenerateStructureScript(from source: DatabaseType, to target: DatabaseType) -> Bool {
        guard source != target else { return true }
        return sameFamily(source, target)
    }

    internal static func sameFamily(_ lhs: DatabaseType, _ rhs: DatabaseType) -> Bool {
        guard lhs != rhs else { return true }
        let key = [lhs.rawValue, rhs.rawValue].sorted().joined(separator: "\u{1F}")
        return compatiblePairKeys.contains(key)
    }

    private static let compatiblePairKeys: Set<String> = {
        let pairs: [[DatabaseType]] = [[.mysql, .mariadb]]
        return Set(pairs.map { $0.map { $0.rawValue }.sorted().joined(separator: "\u{1F}") })
    }()

    internal static func structureScriptRefusal(from source: DatabaseType, to target: DatabaseType) -> String {
        String(
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
