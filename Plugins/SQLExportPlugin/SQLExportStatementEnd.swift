//
//  SQLExportStatementEnd.swift
//  SQLExportPlugin
//

import Foundation
import TableProPluginKit

extension PluginExportDataSource {
    /// What ends every statement of a dump of this source: a line break, and on an engine whose client runs a script in
    /// batches cut at `GO` lines, that line too. SQL Server refuses a view, a routine or a trigger that is not the first
    /// statement of its batch, and a routine's body runs to the end of its batch, so each statement is written as a
    /// batch of its own, the way SQL Server Management Studio writes a script.
    ///
    /// Read off the source each export writes from rather than held by the plugin: `PluginManager` hands every window
    /// the same plugin instance, so a second export started while one runs would otherwise change what the first
    /// writes from then on.
    var dumpStatementEnd: String {
        lexicalFeatures.contains(.batchSeparatorLines) ? "\nGO\n" : "\n"
    }
}
