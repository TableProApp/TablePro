import Foundation
import Observation

/// Pausing is a local, momentary decision: "do not record what I am about to run on this Mac".
/// It deliberately does not live in `HistorySettings`, which syncs, because pausing on a laptop
/// must not silently stop recording on a desktop.
enum QueryHistoryCaptureStore {
    private static let pausedKey = "QueryHistory.capturePaused"

    static var isPaused: Bool {
        get { AppStorageEnvironment.shared.defaults.bool(forKey: pausedKey) }
        set { AppStorageEnvironment.shared.defaults.set(newValue, forKey: pausedKey) }
    }
}

/// Every open drawer shows the same pause state, so it is observed from one place rather than
/// mirrored per connection, where two windows would disagree until one of them reloaded.
@MainActor
@Observable
final class QueryHistoryCaptureState {
    static let shared = QueryHistoryCaptureState()

    var isPaused: Bool {
        didSet {
            guard oldValue != isPaused else { return }
            QueryHistoryCaptureStore.isPaused = isPaused
        }
    }

    private init() {
        isPaused = QueryHistoryCaptureStore.isPaused
    }
}
