//
//  MetadataLoadState.swift
//  TablePro
//

import Foundation

enum MetadataLoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    /// Drops the payload so states over different value types can be compared side by side, which
    /// is what a container row needs when several fetches decide one status row between them.
    var erased: MetadataLoadPhase {
        switch self {
        case .idle:                return .idle
        case .loading:             return .loading
        case .loaded:              return .loaded
        case .failed(let message): return .failed(message)
        }
    }
}

enum MetadataLoadPhase: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(String)

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

extension MetadataLoadState: Equatable where Value: Equatable {}
