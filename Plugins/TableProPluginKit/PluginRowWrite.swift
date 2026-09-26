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

    public init(statement: String, parameters: [PluginCellValue] = [], rowIndices: [Int]) {
        self.statement = statement
        self.parameters = parameters
        self.rowIndices = rowIndices
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
