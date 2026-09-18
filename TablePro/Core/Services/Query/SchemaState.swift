//
//  SchemaState.swift
//  TablePro
//

import Foundation

enum SchemaState: Equatable, Sendable {
    case idle
    case loading
    case loaded([TableInfo])
    case failed(String)
}

extension SchemaState {
    /// The rule `MetadataLoadState.settled` applies to the other object kinds: a failure never
    /// replaces loaded tables unless those tables describe a scope the load has left.
    func settled(byFailure message: String, discardingValue: Bool) -> SchemaState {
        if case .loaded = self, !discardingValue { return self }
        return .failed(message)
    }
}
