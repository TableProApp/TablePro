//
//  OraclePluginDriver+Debugging.swift
//  OracleDriverPlugin
//

import Foundation
import os
import TableProOracleCore
import TableProPluginKit

extension OraclePluginDriver: PluginRoutineDebugging {
    var canDebugRoutines: Bool { true }

    func debugTarget(for routine: PluginRoutineInfo) -> PluginDebugTarget? {
        let kind: OracleDebugUnitKind
        switch routine.kind {
        case .procedure: kind = .procedure
        case .function: kind = .function
        @unknown default: return nil
        }
        if let language = routine.language, language.uppercased() != "PL/SQL" { return nil }
        let owner = effectiveSchema(routine.schema?.isEmpty == false ? routine.schema : nil)
        return Self.debugTarget(OracleDebugUnit(owner: owner, name: routine.name, kind: kind))
    }

    func debugTargets(schema: String?) async throws -> [PluginDebugTarget] {
        let owner = effectiveSchema(schema?.isEmpty == false ? schema : nil)
        let rows = try await rawQuery(OracleDebugStatements.targets(owner: owner)).rows
        return rows.compactMap { row in
            guard let name = row.first?.stringValue,
                  let kind = row.count > 1 ? row[1].stringValue.flatMap(OracleDebugUnitKind.init(rawValue:)) : nil
            else { return nil }
            return Self.debugTarget(OracleDebugUnit(owner: owner, name: name, kind: kind))
        }
    }

    func prepareDebug(_ target: PluginDebugTarget) async throws -> PluginDebugPlan {
        guard let unit = OracleDebugUnit(identity: target.identity) else {
            throw OracleDebugPluginError(message: OracleDebugText.unitUnreadable(target.name))
        }
        let privileges = try await rawQuery(OracleDebugStatements.privileges(of: unit)).rows.first?.map(\.stringValue) ?? []
        if let missing = OracleDebugStatements.missingPrivilege(fromRow: privileges, unit: unit) {
            throw OracleDebugText.error(for: missing, unit: unit)
        }
        let readinessRow = try await rawQuery(OracleDebugStatements.readiness(of: unit)).rows.first?.map(\.stringValue)
        let preparation: PluginDebugPreparation?
        switch OracleDebugStatements.readiness(fromRow: readinessRow) {
        case .notVisible:
            throw OracleDebugPluginError(message: OracleDebugText.unitUnreadable(target.name))
        case .ready:
            preparation = nil
        case .needsDebugCompile:
            preparation = PluginDebugPreparation(
                message: String(format: String(localized: "%@ isn't compiled for debugging."), target.name),
                informativeText: Self.compileForDebugText(unit.kind),
                actionTitle: String(localized: "Compile for Debug"),
                statements: [unit.kind.compileForDebugStatement(owner: unit.owner, name: unit.name)]
            )
        }
        let rows = try await rawQuery(OracleDebugStatements.entryPoints(of: unit)).rows.map { $0.map(\.stringValue) }
        let entryPoints = OracleDebugStatements.parseEntryPoints(rows: rows, unit: unit)
        guard !entryPoints.isEmpty else {
            throw OracleDebugPluginError(message: OracleDebugText.noEntryPoints(target.name))
        }
        debugState.withLock { state in
            for entryPoint in entryPoints {
                state.entryPoints[entryPoint.entry.identity] = entryPoint
            }
        }
        return PluginDebugPlan(
            target: target,
            entryPoints: entryPoints.map(Self.pluginEntryPoint),
            mayWrite: true,
            preparation: preparation,
            options: await debugOptions(),
            note: String(localized: "Changes the routine makes are committed when it finishes. Stop rolls them back.")
        )
    }

    func startDebug(
        _ request: PluginDebugRequest,
        sessions: any PluginDebugSessionSource
    ) async throws -> any PluginDebugSession {
        guard let entry = OracleDebugEntry(identity: request.entryPoint.identity) else {
            throw OracleDebugPluginError(message: OracleDebugText.unitUnreadable(request.entryPoint.displayName))
        }
        let opener = OracleDebugSessionOpener(source: sessions)
        let entryPoint: OracleDebugEntryPoint
        if let cached = debugState.withLock({ $0.entryPoints[entry.identity] }) {
            entryPoint = cached
        } else {
            entryPoint = try await opener.entryPoint(for: entry)
        }
        let values = request.optionValues
        let preference = values[OracleDebugProtocolPreference.fieldID]
            .flatMap(OracleDebugProtocolPreference.init(rawValue:)) ?? .automatic
        let host: String
        if let chosen = values[OracleDebugProtocolPreference.hostFieldID] {
            host = chosen.trimmingCharacters(in: .whitespaces)
        } else {
            host = await defaultDebuggerHost()
        }
        let portsText = values[OracleDebugProtocolPreference.portsFieldID] ?? OracleDebugStatements.defaultPorts
        guard let ports = OracleDebugStatements.ports(from: portsText.isEmpty ? OracleDebugStatements.defaultPorts : portsText) else {
            throw OracleDebugPluginError(message: OracleDebugText.invalidPorts(portsText))
        }
        var arguments: [String: OracleDebugArgumentValue] = [:]
        for argument in request.arguments {
            switch argument.value {
            case .text(let text): arguments[argument.parameterName] = .text(text)
            case .null: arguments[argument.parameterName] = .null
            case .defaultValue: arguments[argument.parameterName] = .defaultValue
            @unknown default: arguments[argument.parameterName] = .null
            }
        }
        let breakpoints = request.breakpoints.compactMap { breakpoint -> OracleDebugBreakpointRequest? in
            OracleDebugUnit(identity: breakpoint.unitIdentity).map { OracleDebugBreakpointRequest(unit: $0, line: breakpoint.line) }
        }
        let launch = OracleDebugLaunch(
            entryPoint: entryPoint,
            arguments: arguments,
            breakpoints: breakpoints,
            preference: preference,
            debuggerHost: host,
            ports: ports,
            databaseHost: config.host,
            databasePort: config.port,
            otherDatabaseHosts: tunneledHost.map { [$0] } ?? []
        )
        do {
            let engine = try await OracleDebugLauncher.launch(launch) { try await opener.open() }
            return OracleRoutineDebugSession(engine: engine)
        } catch {
            throw OracleDebugText.error(for: error, host: host)
        }
    }

    // MARK: - Helpers

    // Recompiling a package body discards its state in every session using it; their next call fails once with
    // ORA-04068.
    static func compileForDebugText(_ kind: OracleDebugUnitKind) -> String {
        let compile = String(localized: """
            TablePro compiles it again with debug information (PLSQL_OPTIMIZE_LEVEL=1) and keeps its other settings. \
            Compiling commits.
            """)
        guard kind.hasSubprograms else { return compile }
        return compile + " " + String(localized: """
            Other sessions using the package lose its state, and their next call to it fails once with ORA-04068.
            """)
    }

    static func debugTarget(_ unit: OracleDebugUnit) -> PluginDebugTarget {
        PluginDebugTarget(
            identity: unit.identity,
            name: unit.name,
            schema: unit.owner,
            kindDisplayName: OracleDebugText.kindName(unit.kind)
        )
    }

    static func pluginEntryPoint(_ entryPoint: OracleDebugEntryPoint) -> PluginDebugEntryPoint {
        PluginDebugEntryPoint(
            identity: entryPoint.entry.identity,
            displayName: entryPoint.displayName,
            parameters: entryPoint.parameters.map { parameter in
                let mode: PluginDebugParameterMode
                switch parameter.mode {
                case .input: mode = .input
                case .output: mode = .output
                case .inputOutput: mode = .inputOutput
                }
                return PluginDebugParameter(
                    name: parameter.name,
                    typeName: parameter.displayType,
                    mode: mode,
                    hasDefault: parameter.hasDefault
                )
            }
        )
    }

    // Asked in the start sheet. A direct connection suggests the address this Mac reaches the database from; through
    // a tunnel or proxy the server sees another host, so the field starts empty and DBMS_DEBUG runs.
    private func debugOptions() async -> [ConnectionField] {
        let jdwpProtocols = [OracleDebugProtocolPreference.automatic.rawValue, OracleDebugProtocolPreference.jdwp.rawValue]
        return [
            ConnectionField(
                id: OracleDebugProtocolPreference.fieldID,
                label: String(localized: "Protocol"),
                defaultValue: OracleDebugProtocolPreference.automatic.rawValue,
                fieldType: .dropdown(options: [
                    ConnectionField.DropdownOption(
                        value: OracleDebugProtocolPreference.automatic.rawValue,
                        label: String(localized: "Automatic")
                    ),
                    ConnectionField.DropdownOption(value: OracleDebugProtocolPreference.jdwp.rawValue, label: "DBMS_DEBUG_JDWP"),
                    ConnectionField.DropdownOption(value: OracleDebugProtocolPreference.dbmsDebug.rawValue, label: "DBMS_DEBUG")
                ]),
                section: .connection
            ),
            ConnectionField(
                id: OracleDebugProtocolPreference.hostFieldID,
                label: String(localized: "Debugger Host"),
                placeholder: String(localized: "Address the database server can reach this Mac at"),
                defaultValue: await defaultDebuggerHost(),
                section: .connection,
                visibleWhen: FieldVisibilityRule(fieldId: OracleDebugProtocolPreference.fieldID, values: jdwpProtocols)
            ),
            ConnectionField(
                id: OracleDebugProtocolPreference.portsFieldID,
                label: String(localized: "Debugger Ports"),
                placeholder: OracleDebugStatements.defaultPorts,
                defaultValue: OracleDebugStatements.defaultPorts,
                section: .connection,
                visibleWhen: FieldVisibilityRule(fieldId: OracleDebugProtocolPreference.fieldID, values: jdwpProtocols)
            )
        ]
    }

    // Behind a tunnel the session dials the forward's loopback address; the server itself is this host.
    private var tunneledHost: String? {
        guard let host = config.additionalFields["preTunnelHost"], !host.isEmpty else { return nil }
        return host
    }

    private func defaultDebuggerHost() async -> String {
        if tunneledHost != nil { return "" }
        guard let route = await OracleDebugNetwork.localAddress(towardHost: config.host, port: config.port) else { return "" }
        // `localhost` routes over ::1 first; a server on this Mac, or Docker Desktop's forward, reaches 127.0.0.1.
        return OracleDebugNetwork.isLoopback(route) ? "127.0.0.1" : route
    }
}

struct OracleDebugState: Sendable {
    var entryPoints: [String: OracleDebugEntryPoint] = [:]
}

// Hands the launcher the sessions the host opens, keeping each one's Oracle connection.
final class OracleDebugSessionOpener: @unchecked Sendable {
    private let source: any PluginDebugSessionSource
    private let lock = NSLock()
    private var opened: [OracleCoreConnection] = []

    init(source: any PluginDebugSessionSource) {
        self.source = source
    }

    func open() async throws -> OracleCoreConnection {
        if let reused = lock.withLock({ opened.isEmpty ? nil : opened.removeFirst() }) {
            return reused
        }
        let driver = try await source.openSession()
        guard let oracle = driver as? OraclePluginDriver, let core = oracle.core, core.isConnected else {
            throw OraclePluginError(core: .notConnected)
        }
        return core
    }

    // Read on the first debug session, which the launcher then takes as its own.
    func entryPoint(for entry: OracleDebugEntry) async throws -> OracleDebugEntryPoint {
        let connection = try await open()
        lock.withLock { opened.append(connection) }
        let rows = try await connection.executeQuery(OracleDebugStatements.entryPoints(of: entry.unit)).rows
        let entryPoints = OracleDebugStatements.parseEntryPoints(rows: rows.map { $0.map(\.stringValue) }, unit: entry.unit)
        guard let entryPoint = entryPoints.first(where: { $0.entry == entry }) else {
            throw OracleDebugPluginError(message: OracleDebugText.noEntryPoints(entry.subprogram))
        }
        return entryPoint
    }
}
