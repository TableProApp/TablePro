import Foundation
import os

enum OracleDebugSupport {
    // Waits for `task` for at most `seconds`; nil when it is still running. The task keeps running either way.
    static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let slot = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
        let take: @Sendable () -> CheckedContinuation<T?, Never>? = {
            slot.withLock { stored in
                let continuation = stored
                stored = nil
                return continuation
            }
        }
        return await withCheckedContinuation { continuation in
            slot.withLock { $0 = continuation }
            Task {
                let value = await task.value
                take()?.resume(returning: value)
            }
            Task {
                try? await Task.sleep(nanoseconds: OracleQueryTimeout.nanoseconds(seconds))
                take()?.resume(returning: nil)
            }
        }
    }

    static func rows(_ result: OracleRawResult) -> [[String?]] {
        result.rows.map { row in row.map(\.stringValue) }
    }

    static func source(of unit: OracleDebugUnit, on connection: any OracleDebugChannel) async throws -> String {
        let result = try await connection.executeQuery(OracleDebugStatements.source(of: unit))
        let lines = rows(result).compactMap { row -> (line: Int, text: String?)? in
            guard let line = row.first.flatMap({ $0 }).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
            else { return nil }
            return (line, row.count > 1 ? row[1] : nil)
        }
        guard !lines.isEmpty else { throw OracleDebugError.unitNotFound }
        return OracleDebugStatements.assembleSource(rows: lines)
    }

    static func executableLines(of unit: OracleDebugUnit, on connection: any OracleDebugChannel) async throws -> [Int]? {
        let fields = try await payload(OracleDBMSDebugStatements.lineMap(of: unit), on: connection)
        return try OracleDBMSDebugStatements.executableLines(fromPayload: fields)
    }

    static func payload(
        _ block: String,
        binds: [OracleBindValue] = [],
        autoCommit: Bool = false,
        on connection: any OracleDebugChannel
    ) async throws -> [String?] {
        let pieces = try await connection.executeDirect(block, binds: binds, autoCommit: autoCommit, readsRows: true)
        do {
            return try OracleDebugPayload.parse(OracleDebugPayload.join(pieces: pieces))
        } catch {
            throw OracleDebugError.unreadableAnswer
        }
    }

    // How long the routine's call gets to return once the debugger has seen it end or lost the target.
    static let callEndWait: Duration = .seconds(30)

    // The routine's own result: its outputs on success; a rollback otherwise, and always after Stop. Nil is a call
    // still running, which holds the target's gate: a ROLLBACK would queue behind it with no bound.
    static func conclude(
        _ result: Result<[String?], Error>?,
        stopped: Bool,
        entryPoint: OracleDebugEntryPoint,
        target: any OracleDebugChannel,
        targetIdentity: OracleDebugSessionIdentity?,
        notice: @Sendable (OracleDebugNotice) -> Void
    ) async -> OracleDebugStop {
        guard let result else { return .failed(.stillRunning(targetIdentity)) }
        let report: OracleDebugStatements.InvocationReport?
        switch result {
        case .success(let pieces):
            report = try? OracleDebugStatements.invocationReport(
                fromPayload: OracleDebugPayload.parse(OracleDebugPayload.join(pieces: pieces))
            )
        case .failure:
            report = nil
        }
        for line in report?.lines ?? [] {
            notice(.serverOutput(line))
        }
        if !stopped, let report, report.succeeded {
            do {
                _ = try await target.executeDirect("COMMIT")
            } catch {
                return .failed(.connectionLost(Self.message(of: error)))
            }
            return .finished(outcome(of: report, entryPoint: entryPoint))
        }
        _ = try? await target.executeDirect("ROLLBACK")
        if stopped { return .failed(.stopped) }
        if let report {
            return .failed(.routineFailed(report.error ?? ""))
        }
        if case .failure(let error) = result {
            return .failed(.routineFailed(Self.message(of: error)))
        }
        return .failed(.connectionLost(nil))
    }

    static func outcome(of report: OracleDebugStatements.InvocationReport, entryPoint: OracleDebugEntryPoint) -> OracleDebugOutcome {
        var types: [String: String] = [:]
        for parameter in entryPoint.parameters {
            types[parameter.name] = parameter.displayType
        }
        if let result = entryPoint.result {
            types[entryPoint.entry.subprogram] = result.displayType
        }
        return OracleDebugOutcome(values: report.outputs.map {
            OracleDebugOutcome.Value(name: $0.name, typeName: types[$0.name] ?? "", value: $0.value)
        })
    }

    // The target's SID and SERIAL#, read before it is attached to a debugger, so its own PL/SQL does not stop it.
    static func sessionIdentity(of connection: any OracleDebugChannel) async -> OracleDebugSessionIdentity? {
        for query in OracleDBMSDebugStatements.sessionIdentityQueries {
            guard let row = try? await connection.executeQuery(query).rows.first?.map(\.stringValue),
                  let identity = OracleDBMSDebugStatements.sessionIdentity(fromRow: row) else { continue }
            return identity
        }
        return nil
    }

    // The server ends a killed session at its next check, even inside a loop or a SQL statement, and rolls its work
    // back. ORA-00031 "session marked for kill" is that taking effect on a busy session (measured: the target then
    // failed with ORA-00028); ORA-01031 is a session without ALTER SYSTEM.
    // A read Stop overlaps holds the connection's gate first; past `seconds` the channel is closed, which ends both.
    static func kill(
        _ identity: OracleDebugSessionIdentity?,
        from connection: any OracleDebugChannel,
        within seconds: Double
    ) async -> OracleDebugStopBudget.KillOutcome {
        guard let identity, let statement = OracleDBMSDebugStatements.killSession(identity), seconds > 0 else {
            return .refused
        }
        do {
            _ = try await withOracleTimeout(seconds: seconds, onTimeout: { connection.cancelCurrentQuery() }) {
                try await connection.executeDirect(statement)
            }
            return .marked
        } catch {
            return OracleDebugStatements.errorCodes(in: message(of: error)).contains(31) ? .marked : .refused
        }
    }

    static func message(of error: Error) -> String {
        if let core = error as? OracleCoreError {
            return core.errorDescription ?? String(describing: core)
        }
        return String(describing: error)
    }
}
