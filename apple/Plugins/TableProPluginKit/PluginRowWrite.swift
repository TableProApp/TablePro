//
//  PluginRowWrite.swift
//  TableProPluginKit
//

import Foundation

/// One statement a driver writes for a save, and the changes it carries out.
///
/// `rowIndices` holds the `PluginRowChange.rowIndex` of every change the statement writes. The
/// host refuses a save when a pending change is named by no statement, so a statement that writes
/// several changes, such as one delete for many rows, names all of them.
///
/// Deliberately not `@frozen`, so it can gain a field later. Any new field arrives with its own
/// initializer overload; this one keeps its signature, because changing it would replace the
/// mangled symbol every already-built plugin references.
public struct PluginRowWrite: Sendable {
    public let statement: String
    public let parameters: [PluginCellValue]
    public let rowIndices: [Int]
    public let lookup: PluginRowLookup?

    @_disfavoredOverload
    public init(statement: String, parameters: [PluginCellValue] = [], rowIndices: [Int]) {
        self.init(statement: statement, parameters: parameters, rowIndices: rowIndices, lookup: nil)
    }

    public init(statement: String, parameters: [PluginCellValue] = [], rowIndices: [Int], lookup: PluginRowLookup? = nil) {
        self.statement = statement
        self.parameters = parameters
        self.rowIndices = rowIndices
        self.lookup = lookup
    }
}

// For an engine with no key that names one row. The host runs `query` right before the write and refuses it unless
// exactly `rowCount` rows come back; with `pinsRows` their values are bound after the write's own parameters, row by
// row. Right after the write, a row back from `check` means it did not land.
public struct PluginRowLookup: Sendable, Equatable {
    public let query: String
    public let parameters: [PluginCellValue]
    public let rowCount: Int
    public let pinsRows: Bool
    public let check: String?
    public let checkParameters: [PluginCellValue]

    public init(
        query: String,
        parameters: [PluginCellValue],
        rowCount: Int,
        pinsRows: Bool,
        check: String? = nil,
        checkParameters: [PluginCellValue] = []
    ) {
        self.query = query
        self.parameters = parameters
        self.rowCount = rowCount
        self.pinsRows = pinsRows
        self.check = check
        self.checkParameters = checkParameters
    }
}

/// A change the driver cannot write, with the reason in the user's language.
///
/// Thrown from `generateRowWrites` in place of leaving the change out. The host then sends nothing,
/// keeps every change pending, and shows `reason`, so it should say what is wrong with the change
/// rather than restate that it failed.
public struct PluginRowWriteRefusal: Error, LocalizedError, Sendable, Equatable {
    public let rowIndex: Int
    public let reason: String

    public init(rowIndex: Int, reason: String) {
        self.rowIndex = rowIndex
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}
