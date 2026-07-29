import Foundation

enum Loadable<T> {
    case loading
    case loaded(T)
    case failed(Error)
}

extension Loadable {
    var value: T? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum LoadStatus: Equatable, Sendable {
    case loading
    case ready
    case failed
}

extension Loadable {
    var status: LoadStatus {
        switch self {
        case .loading: return .loading
        case .loaded: return .ready
        case .failed: return .failed
        }
    }
}
