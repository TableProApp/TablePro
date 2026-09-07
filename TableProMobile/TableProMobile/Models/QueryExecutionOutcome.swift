import Foundation
import TableProModels

nonisolated enum QueryExecutionOutcome: Equatable, Sendable {
    case completed
    case failed
    case stopped
    case interrupted

    init(phase: QueryEditorViewModel.Phase) {
        switch phase {
        case .finished:
            self = .completed
        case .error:
            self = .failed
        case .truncated(let reason):
            self = Self(truncation: reason)
        case .idle, .running:
            self = .interrupted
        }
    }

    private init(truncation: TruncationReason) {
        switch truncation {
        case .rowCap, .driverLimit:
            self = .completed
        case .cancelled:
            self = .stopped
        case .memoryPressure:
            self = .interrupted
        @unknown default:
            self = .interrupted
        }
    }

    var activityOutcome: QueryActivityAttributes.Outcome {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .stopped: .stopped
        case .interrupted: .interrupted
        }
    }

    var historyMessage: String? {
        switch self {
        case .completed, .failed:
            nil
        case .stopped:
            String(localized: "Stopped before the query finished.")
        case .interrupted:
            String(localized: "Interrupted before the query finished.")
        }
    }
}
