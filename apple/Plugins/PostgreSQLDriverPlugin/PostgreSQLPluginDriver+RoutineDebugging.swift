//
//  PostgreSQLPluginDriver+RoutineDebugging.swift
//  PostgreSQLDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProPostgreSQLCore

// pldbgapi direct debugging. Redshift and CockroachDB are siblings of this class, not subclasses, so they never
// conform; PGlite inherits the conformance and turns it off through `canDebugRoutines`.
extension PostgreSQLPluginDriver: PluginRoutineDebugging {
    func debugTarget(for routine: PluginRoutineInfo) -> PluginDebugTarget? {
        guard canDebugRoutines else { return nil }
        return PostgreSQLRoutineDebugProtocol.target(for: routine)
    }

    func debugTargets(schema: String?) async throws -> [PluginDebugTarget] {
        guard canDebugRoutines else { return [] }
        let query = PostgreSQLRoutineDebugProtocol.targetListQuery(
            schema: schema ?? currentSchema ?? "public",
            hasProcedureKind: catalogCapabilities.hasProcedureKind
        )
        let result = try await execute(query: query)
        return result.rows.compactMap { PostgreSQLRoutineDebugProtocol.target(fromListRow: $0.map(\.asText)) }
    }

    func prepareDebug(_ target: PluginDebugTarget) async throws -> PluginDebugPlan {
        guard canDebugRoutines else { throw PostgreSQLRoutineDebugError.unavailable }
        let routine = try await debugRoutine(identity: target.identity, name: target.name)
        _ = try routine.debuggerSchema()
        return PluginDebugPlan(
            target: target,
            entryPoints: [routine.entryPoint],
            // Any routine can write: a STABLE label does not stop a default such as nextval() or a volatile callee.
            mayWrite: true,
            note: routine.runNote
        )
    }

    func startDebug(
        _ request: PluginDebugRequest,
        sessions: any PluginDebugSessionSource
    ) async throws -> any PluginDebugSession {
        guard canDebugRoutines else { throw PostgreSQLRoutineDebugError.unavailable }
        let target = try await Self.debugSession(from: sessions)
        let proxy = try await Self.debugSession(from: sessions)
        try await proxy.prepareForDebugging(isTarget: false)

        let routine = try await proxy.debugRoutine(
            identity: request.entryPoint.identity,
            name: request.entryPoint.displayName
        )
        let extensionSchema = try routine.debuggerSchema()
        try await target.prepareForDebugging(isTarget: true)
        let targetProcess = try? await target.execute(query: "SELECT pg_catalog.pg_backend_pid()")
            .rows.first?.first?.asText.flatMap { Int($0) }
        let call = try PostgreSQLRoutineDebugProtocol.call(for: routine, arguments: request.arguments)
        guard let oid = UInt32(routine.identity) else {
            throw PostgreSQLRoutineDebugError.routineNotFound(routine.displayName)
        }
        do {
            _ = try await target.execute(
                query: PostgreSQLRoutineDebugProtocol.oidDebugStatement(extensionSchema: extensionSchema, oid: oid)
            )
        } catch {
            throw PostgreSQLRoutineDebugProtocol.startFailure(
                error,
                database: routine.database,
                routineName: routine.displayName
            )
        }

        // Nothing runs on the target yet, so a cancelled start leaves nothing behind.
        try Task.checkCancellation()
        let session = PostgreSQLRoutineDebugSession(
            target: target,
            proxy: proxy,
            sessions: sessions,
            routine: routine,
            extensionSchema: extensionSchema,
            targetProcess: targetProcess,
            breakpoints: request.breakpoints
        )
        try await session.start(call)
        return session
    }

    static func debugSession(from sessions: any PluginDebugSessionSource) async throws -> PostgreSQLPluginDriver {
        guard let driver = try await sessions.openSession() as? PostgreSQLPluginDriver, driver.canDebugRoutines else {
            throw PostgreSQLRoutineDebugError.unavailable
        }
        return driver
    }

    private func prepareForDebugging(isTarget: Bool) async throws {
        // Before the settings, which a rollback would undo.
        if PostgreSQLRoutineDebugProtocol.endsStartupTransaction(await sessionTransactionState()) {
            _ = try await execute(query: "ROLLBACK")
        }
        let statements = PostgreSQLRoutineDebugProtocol.sessionSettings(
            serverVersion: serverVersionNumber,
            isTarget: isTarget
        )
        for statement in statements {
            _ = try await execute(query: statement)
        }
    }

    private func debugRoutine(identity: String, name: String) async throws -> PostgreSQLDebugRoutine {
        guard let oid = PostgreSQLRoutineDebugProtocol.oid(inIdentity: identity) else {
            throw PostgreSQLRoutineDebugError.routineNotFound(name)
        }
        let query = PostgreSQLRoutineDebugProtocol.routineQuery(
            oid: oid,
            hasProcedureKind: catalogCapabilities.hasProcedureKind
        )
        let result = try await execute(query: query)
        guard let row = result.rows.first else { throw PostgreSQLRoutineDebugError.routineNotFound(name) }
        let routine = PostgreSQLDebugRoutine(row: row.map(\.asText), identity: String(oid))
        guard routine.exists else { throw PostgreSQLRoutineDebugError.routineNotFound(name) }
        return routine
    }
}
