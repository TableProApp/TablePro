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

    var label: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded: return "loaded"
        case .failed: return "failed"
        }
    }
}

extension MetadataLoadState: Equatable where Value: Equatable {}

extension SchemaState {
    var label: String {
        switch self {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded(let tables): return "loaded(\(tables.count))"
        case .failed: return "failed"
        }
    }
}

extension ConnectionStatus {
    var label: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error: return "error"
        }
    }
}
