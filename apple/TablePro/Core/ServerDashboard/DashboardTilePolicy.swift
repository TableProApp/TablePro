//
//  DashboardTilePolicy.swift
//  TablePro
//

import Foundation

/// What a tile refuses before it asks the execution gate. A tile runs on a timer with nobody to
/// confirm anything, so it takes a single statement that only reads, and says why it will not.
enum DashboardTilePolicy {
    static func refusal(
        for sql: String,
        databaseType: DatabaseType,
        forcesWrite: Bool
    ) -> String? {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "This saved query is empty.")
        }
        if forcesWrite {
            return String(localized: "This database cannot run a statement read-only, so tiles do not run on it.")
        }
        let classification = QueryClassifier.classify(sql, databaseType: databaseType)
        if classification.reachesFilesystemOrExecutesCode {
            return String(localized: "This saved query reads or writes files or runs server-side code. Tiles run reads only.")
        }
        if QueryClassifier.isMultiStatement(sql, databaseType: databaseType) {
            return String(localized: "This saved query holds more than one statement. A tile runs one.")
        }
        if classification.tier != .safe {
            return String(localized: "This saved query is not a read. Tiles run reads only.")
        }
        return nil
    }
}
