//
//  SQLExportSessionScope.swift
//  SQLExportPlugin
//

import Foundation

/// A pair of statements a part has to carry together: the opener establishes session state the
/// statements after it depend on, and the closer puts it back.
///
/// Replaying the parts of a split dump in order gets the statements in the same order as an unsplit
/// one, but not in one session, so session state cannot be assumed to cross a part boundary. A
/// scope therefore belongs to every part it spans rather than to the file: the writer re-opens it
/// at the top of each new part and closes it at the bottom of each finished one.
internal struct SQLExportSessionScope: Equatable {
    internal let opener: String
    internal let closer: String

    /// SQL Server refuses an explicit value for an IDENTITY column unless the table is opened for
    /// it first, so a part carrying any of that table's rows has to open it again. Written as two
    /// plain statements, one `ON` per table and one `OFF` after the stream, a rotation between them
    /// left part N+1 answering every row with "Cannot insert explicit value for identity column"
    /// while the export reported success (#2533).
    internal static func identityInsert(tableRef: String) -> SQLExportSessionScope {
        SQLExportSessionScope(
            opener: "SET IDENTITY_INSERT \(tableRef) ON;\n",
            closer: "SET IDENTITY_INSERT \(tableRef) OFF;\n")
    }
}
