//
//  VerbatimTransferScopes.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

/// A driver's session scope calls, for callers that hold it as a plugin driver or as a host driver.
internal struct SessionScopeHandle: Sendable {
    fileprivate let open: @Sendable (PluginSessionPurpose) async throws -> PluginSessionScope?
    fileprivate let close: @Sendable (PluginSessionScope) async throws -> Void

    internal init(_ driver: any PluginDatabaseDriver) {
        open = { try await driver.openSessionScope(for: $0) }
        close = { try await driver.closeSessionScope($0) }
    }

    internal init(_ driver: DatabaseDriver) {
        open = { try await driver.openSessionScope(for: $0) }
        close = { try await driver.closeSessionScope($0) }
    }
}

/// The session scopes a same-engine row copy runs under, so the target takes back what the source
/// held: zero dates, an AUTO_INCREMENT 0, TIMESTAMPs in one zone.
internal struct VerbatimTransferScopes: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "VerbatimTransferScopes")

    private struct Held: Sendable {
        let handle: SessionScopeHandle
        let scope: PluginSessionScope
    }

    private let held: [Held]

    /// Object Copy's own test for whether a copy crosses engines, so both copy paths agree on it.
    internal static func isSameEngine(source: DatabaseType, target: DatabaseType) -> Bool {
        !SQLTypeFamily.needsTranslation(from: source, to: target)
    }

    /// A row filter is the user's SQL, written for their own session: under pinned settings a `NOW()`
    /// or a TIMESTAMP literal selects other rows, and a double-quoted identifier becomes a string. A
    /// copy that reads one keeps both sessions as they are. A column list or a row limit means the
    /// same either way. The SQL export follows the same rule.
    internal static func filtersRows(_ rowScope: PluginExportRowScope?) -> Bool {
        !(rowScope?.sanitizedFilter.isEmpty ?? true)
    }

    /// Both or neither: a value read under one side's scope is only safe to write under the other's.
    internal static func open(
        reading source: SessionScopeHandle,
        writing target: SessionScopeHandle
    ) async -> VerbatimTransferScopes? {
        guard let read = await open(.verbatimRead, on: source) else { return nil }
        let reading = Held(handle: source, scope: read)
        guard let write = await open(.verbatimWrite, on: target) else {
            await close(reading)
            return nil
        }
        return VerbatimTransferScopes(held: [reading, Held(handle: target, scope: write)])
    }

    /// For an `INSERT ... SELECT`, whose rows never leave the server that writes them, and for DDL
    /// read earlier under `open(reading:)`.
    internal static func open(writing target: SessionScopeHandle) async -> VerbatimTransferScopes? {
        guard let write = await open(.verbatimWrite, on: target) else { return nil }
        return VerbatimTransferScopes(held: [Held(handle: target, scope: write)])
    }

    /// For definitions read in one lease and written in a later one under `open(writing:)`.
    internal static func open(reading source: SessionScopeHandle) async -> VerbatimTransferScopes? {
        guard let read = await open(.verbatimRead, on: source) else { return nil }
        return VerbatimTransferScopes(held: [Held(handle: source, scope: read)])
    }

    /// Last opened, first closed: one unpooled session can serve both sides, and each scope saved
    /// what the one before it had set.
    internal func close() async {
        for entry in held.reversed() {
            await Self.close(entry)
        }
    }

    private static func open(_ purpose: PluginSessionPurpose, on handle: SessionScopeHandle) async -> PluginSessionScope? {
        do {
            return try await handle.open(purpose)
        } catch {
            logger.warning(
                "Opening the \(String(describing: purpose), privacy: .public) session scope failed: \(error.publicLogShape, privacy: .public)"
            )
            return nil
        }
    }

    /// Shielded like a rollback: a Stop is often what ends the copy, and the session, sometimes the
    /// user's own editor session, still needs its settings back.
    private static func close(_ entry: Held) async {
        do {
            try await TaskCancellationShield.run { try await entry.handle.close(entry.scope) }
        } catch {
            logger.error(
                "Closing the \(String(describing: entry.scope.purpose), privacy: .public) session scope failed: \(error.publicLogShape, privacy: .public)"
            )
        }
    }
}
