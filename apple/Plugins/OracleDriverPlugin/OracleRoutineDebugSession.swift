//
//  OracleRoutineDebugSession.swift
//  OracleDriverPlugin
//

import Foundation
import TableProOracleCore
import TableProPluginKit

final class OracleRoutineDebugSession: PluginDebugSession, @unchecked Sendable {
    private let engine: any OracleDebugEngine
    let output: AsyncStream<String>

    // Step Out works on both: JDWP's OUT depth and DBMS_DEBUG's break_any_return each stop in the caller (measured).
    let supportedCommands: Set<PluginDebugCommand> = [.continueExecution, .stepOver, .stepInto, .stepOut]

    init(engine: any OracleDebugEngine) {
        self.engine = engine
        let notices = engine.notices
        output = AsyncStream { continuation in
            let task = Task {
                for await notice in notices {
                    continuation.yield(OracleDebugText.line(for: notice))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func firstStop() async throws -> PluginDebugStop {
        try await run { try await engine.firstStop() }
    }

    func perform(_ command: PluginDebugCommand) async throws -> PluginDebugStop {
        let mapped: OracleDebugCommand
        switch command {
        case .continueExecution: mapped = .continueExecution
        case .stepOver: mapped = .stepOver
        case .stepInto: mapped = .stepInto
        case .stepOut: mapped = .stepOut
        @unknown default: mapped = .continueExecution
        }
        return try await run { try await engine.perform(mapped) }
    }

    private func run(_ body: () async throws -> OracleDebugStop) async throws -> PluginDebugStop {
        do {
            return Self.pluginStop(try await body())
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func source(of unit: PluginDebugUnit) async throws -> String {
        guard let oracleUnit = OracleDebugUnit(identity: unit.identity) else {
            throw OracleDebugPluginError(message: OracleDebugText.unitUnreadable(unit.displayName))
        }
        do {
            return try await engine.source(of: oracleUnit)
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func stack() async throws -> [PluginDebugFrame] {
        do {
            return try await engine.stack().map { frame in
                PluginDebugFrame(level: frame.level, location: Self.location(frame.location), arguments: frame.subprogram)
            }
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func variables(inFrame level: Int) async throws -> [PluginDebugVariable] {
        do {
            return try await engine.variables(inFrame: level).map { variable in
                let kind: PluginDebugVariableKind
                switch variable.kind {
                case .argument: kind = .argument
                case .local: kind = .local
                case .package: kind = .package
                }
                return PluginDebugVariable(
                    name: variable.name,
                    kind: kind,
                    typeName: variable.typeName,
                    value: OracleDebugText.text(for: variable.value),
                    isConstant: variable.isConstant
                )
            }
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func setBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws -> PluginDebugBreakpoint? {
        guard let unit = OracleDebugUnit(identity: breakpoint.unitIdentity) else { return nil }
        do {
            guard let line = try await engine.setBreakpoint(in: unit, line: breakpoint.line) else { return nil }
            return PluginDebugBreakpoint(unitIdentity: breakpoint.unitIdentity, line: line)
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func removeBreakpoint(_ breakpoint: PluginDebugBreakpoint) async throws {
        guard let unit = OracleDebugUnit(identity: breakpoint.unitIdentity) else { return }
        do {
            try await engine.removeBreakpoint(in: unit, line: breakpoint.line)
        } catch {
            throw OracleDebugText.error(for: error, host: nil)
        }
    }

    func stop() async {
        await engine.stop()
    }

    static func location(_ location: OracleDebugLocation) -> PluginDebugLocation {
        PluginDebugLocation(unit: unit(location.unit), line: location.line)
    }

    static func unit(_ unit: OracleDebugUnit) -> PluginDebugUnit {
        let name = "\(unit.owner).\(unit.name)"
        let displayName = unit.kind == .package || unit.kind == .type
            ? String(format: String(localized: "%@ (specification)"), name)
            : name
        return PluginDebugUnit(identity: unit.identity, displayName: displayName)
    }

    static func pluginStop(_ stop: OracleDebugStop) -> PluginDebugStop {
        switch stop {
        case .paused(let location):
            return .paused(Self.location(location))
        case .finished(let outcome):
            guard !outcome.values.isEmpty else { return .finished(nil) }
            return .finished(PluginQueryResult(
                columns: outcome.values.map(\.name),
                columnTypeNames: outcome.values.map(\.typeName),
                rows: [outcome.values.map { $0.value.map(PluginCellValue.text) ?? .null }],
                rowsAffected: 0,
                timing: PluginQueryTiming(total: 0)
            ))
        case .failed(let failure):
            let text = OracleDebugText.failure(failure)
            return .failed(message: text.message, detail: text.detail)
        }
    }
}
