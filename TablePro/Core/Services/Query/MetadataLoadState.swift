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

    var isSettled: Bool {
        switch self {
        case .loaded, .failed: return true
        case .idle, .loading: return false
        }
    }
}

extension MetadataLoadState: Equatable where Value: Equatable {}
