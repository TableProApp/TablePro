//
//  SQLExportReadScope.swift
//  SQLExportPlugin
//

import Foundation
import os
import TableProPluginKit

/// The driver pins the read session, such as MySQL's `time_zone`, so the dump's values read back the same on the
/// server that loads it. The export reads on the user's own session, so every exit puts it back.
internal struct SQLExportReadScope {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLExportReadScope")

    private var scope: PluginSessionScope?

    internal let readTimeZone: String?
    internal let readsWithANSIQuotes: Bool

    private init(scope: PluginSessionScope?, sqlMode: String?) {
        self.scope = scope
        self.readTimeZone = scope?.appliedValue(of: "time_zone")
        self.readsWithANSIQuotes = sqlMode?
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("ANSI_QUOTES") == .orderedSame }
            ?? false
    }

    /// A failed open leaves the session as it was, so the export reads the way it did before scopes existed and
    /// the dump declares nothing the read did not pin.
    ///
    /// A row filter is the user's SQL, written for their own session: under the pinned zone and mode a `NOW()` or a
    /// TIMESTAMP literal selects other rows, and a double-quoted identifier becomes a string. An export with one
    /// reads as the session is. A column list or a row limit means the same either way.
    internal static func open(
        on dataSource: any PluginExportDataSource,
        for tables: [PluginExportTable]
    ) async -> SQLExportReadScope {
        if tables.contains(where: { !$0.rowScope.sanitizedFilter.isEmpty }) {
            Self.logger.info("Export reads without a read scope, because a row filter runs on the user's session")
        } else if let scope = await openPinnedRead(on: dataSource) {
            return SQLExportReadScope(scope: scope, sqlMode: scope.appliedValue(of: "sql_mode"))
        }
        return SQLExportReadScope(scope: nil, sqlMode: await sessionSQLMode(on: dataSource))
    }

    private static func openPinnedRead(on dataSource: any PluginExportDataSource) async -> PluginSessionScope? {
        do {
            return try await dataSource.openSessionScope(for: .verbatimRead)
        } catch {
            Self.logger.warning("Failed to open the export read scope: \(error.localizedDescription)")
            return nil
        }
    }

    /// The mode the server spells the DDL under when the read is not pinned. `.preserve` applies nothing and saves the
    /// session's own values, so opening and closing it at once reads them. Nil when it cannot tell.
    private static func sessionSQLMode(on dataSource: any PluginExportDataSource) async -> String? {
        let probe: PluginSessionScope?
        do {
            probe = try await dataSource.openSessionScope(for: .preserve)
        } catch {
            Self.logger.warning("Failed to read the export session's settings: \(error.localizedDescription)")
            return nil
        }
        guard let probe else { return nil }
        do {
            try await dataSource.closeSessionScope(probe)
        } catch {
            Self.logger.warning("Failed to close the export session probe: \(error.localizedDescription)")
        }
        return probe.saved.first { $0.name.caseInsensitiveCompare("sql_mode") == .orderedSame }?.value
    }

    /// Closes once however many exits reach it. A failed close is logged rather than thrown, for the reason
    /// `SQLExportSnapshot.end` gives.
    internal mutating func close(on dataSource: any PluginExportDataSource) async {
        guard let scope else { return }
        self.scope = nil
        do {
            try await dataSource.closeSessionScope(scope)
        } catch {
            Self.logger.warning("Failed to close the export read scope: \(error.localizedDescription)")
        }
    }
}
