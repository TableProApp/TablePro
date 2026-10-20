import Foundation

nonisolated enum CellLookupError: LocalizedError, Equatable {
    case rowNotFound

    var errorDescription: String? {
        switch self {
        case .rowNotFound:
            String(localized: "This row is no longer in the table. Another session may have changed its key or deleted it.")
        }
    }
}
