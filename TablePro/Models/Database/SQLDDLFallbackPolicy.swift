//
//  SQLDDLFallbackPolicy.swift
//  TablePro
//

import Foundation
import TableProConnectionLibrary

/// The Mac app's view of `TableProConnectionLibrary.SQLDDLFallbackPolicy`, in terms of its own
/// `DatabaseType`.
///
/// The list itself lives in `TableProConnectionLibrary` because iOS hardcoded the same DDL in
/// `TableProMobile/Views/TableListView.swift` and needs the same answer, and that is one of the
/// five package targets both apps link. The two apps do not share `DatabaseType`, so the shared
/// list keys on the raw id and this maps it back.
extension SQLDDLFallbackPolicy {
    /// Engines with no SQL DDL to fall back on, as this app's `DatabaseType`.
    static var enginesWithoutSQLDDL: Set<DatabaseType> {
        Set(engineIdsWithoutSQLDDL.map { DatabaseType(rawValue: $0) })
    }

    /// True when `DROP`/`TRUNCATE` built by the app is something this engine could run.
    static func allowsGeneratedDDL(for databaseType: DatabaseType) -> Bool {
        allowsGeneratedDDL(databaseTypeId: databaseType.rawValue)
    }
}
