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

/// What one metadata fetch came back with, before it is committed over the state it refreshes.
enum MetadataFetchOutcome<Value: Sendable>: Sendable {
    case fetched(Value)
    case failed(String)
    case cancelled

    var didFetch: Bool {
        if case .fetched = self { return true }
        return false
    }
}

extension MetadataLoadState {
    /// Loading is entered only with nothing to show, so a refresh keeps the rows it is refreshing.
    var enteringLoad: MetadataLoadState {
        if case .loaded = self { return self }
        return .loading
    }

    /// A failure never replaces loaded rows unless those rows describe a scope the load has left,
    /// and a cancelled fetch never leaves a spinner behind with nothing coming to replace it.
    func settled(by outcome: MetadataFetchOutcome<Value>, discardingValue: Bool) -> MetadataLoadState {
        switch outcome {
        case .fetched(let value):
            return .loaded(value)
        case .failed(let message):
            if case .loaded = self, !discardingValue { return self }
            return .failed(message)
        case .cancelled:
            if discardingValue { return .idle }
            if case .loading = self { return .idle }
            return self
        }
    }
}
