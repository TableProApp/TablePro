//
//  SequenceEditing.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

// The four numbers as typed, so the sheet can say which one does not parse.
struct SequenceSettingsDraft: Equatable {
    var increment: String
    var minValue: String
    var maxValue: String
    var cacheSize: String
    var cycles: Bool

    init(_ settings: PluginSequenceSettings) {
        increment = String(settings.increment)
        minValue = String(settings.minValue)
        maxValue = String(settings.maxValue)
        cacheSize = String(settings.cacheSize)
        cycles = settings.cycles
    }

    enum Problem: Error, Equatable {
        case notANumber
        case zeroIncrement
        case minimumNotBelowMaximum
        case cacheBelowOne

        var message: String {
            switch self {
            case .notANumber: String(localized: "Enter whole numbers only.")
            case .zeroIncrement: String(localized: "The increment cannot be zero.")
            case .minimumNotBelowMaximum: String(localized: "The minimum must be less than the maximum.")
            case .cacheBelowOne: String(localized: "The cache must be at least 1.")
            }
        }
    }

    var settings: Result<PluginSequenceSettings, Problem> {
        guard let increment = Self.number(increment),
              let minValue = Self.number(minValue),
              let maxValue = Self.number(maxValue),
              let cacheSize = Self.number(cacheSize)
        else { return .failure(.notANumber) }
        if increment == 0 { return .failure(.zeroIncrement) }
        if minValue >= maxValue { return .failure(.minimumNotBelowMaximum) }
        if cacheSize < 1 { return .failure(.cacheBelowOne) }
        return .success(PluginSequenceSettings(
            increment: increment, minValue: minValue, maxValue: maxValue, cacheSize: cacheSize, cycles: cycles
        ))
    }

    static func number(_ text: String) -> Int64? {
        Int64(text.trimmingCharacters(in: .whitespaces))
    }
}

@MainActor
enum SequenceEditing {
    // Read fresh, not from the sidebar's listing, which may predate a nextval in another session.
    static func details(
        of target: DatabaseObjectTarget,
        provider: any ScopedMetadataProviding = DatabaseManager.shared
    ) async throws -> PluginSequenceDetails {
        let name = target.name
        let schema = target.schema
        let details = try await provider.withMetadataDriver(scope: target.scope) { driver in
            try await driver.fetchSequenceDetails(sequence: name, schema: schema)
        }
        guard let details else { throw DatabaseObjectCommandError.unsupported }
        return details
    }

    static func setNextValue(
        _ nextValue: PluginSequenceNextValue,
        of sequence: PluginSequenceDetails,
        target: DatabaseObjectTarget,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseObjectCommandError.notConnected
        }
        guard let sql = driver.sequenceNextValueStatement(for: sequence, nextValue: nextValue) else {
            throw DatabaseObjectCommandError.unsupported
        }
        try await DatabaseObjectCommandRunner.run(
            sql,
            in: target.scope,
            connection: connection,
            kind: .writeQuery,
            operationDescription: String(localized: "Set Next Value"),
            gate: gate
        )
        AppCommands.shared.objectChanged.send(target.change(.rows))
    }

    static func alter(
        _ sequence: PluginSequenceDetails,
        to settings: PluginSequenceSettings,
        target: DatabaseObjectTarget,
        connection: DatabaseConnection,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let driver = DatabaseManager.shared.driver(for: connection.id) else {
            throw DatabaseObjectCommandError.notConnected
        }
        guard let sql = driver.alterSequenceStatement(for: sequence, settings: settings) else {
            throw DatabaseObjectCommandError.unsupported
        }
        try await DatabaseObjectCommandRunner.run(
            sql,
            in: target.scope,
            connection: connection,
            kind: .schemaMutation,
            operationDescription: String(localized: "Edit Sequence"),
            gate: gate
        )
        AppCommands.shared.objectChanged.send(target.change(.structure))
    }
}
