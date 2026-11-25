import Foundation

public enum DuckDBConnectionMode: String, Sendable, Equatable, CaseIterable {
    case local
    case remote
    case motherDuck = "motherduck"

    public static let fieldId = "duckdbMode"

    // An unknown value is nil, never local: opening the hidden file path would connect where the user did not ask.
    public init?(fieldValue: String?) {
        guard let fieldValue, !fieldValue.isEmpty else {
            self = .local
            return
        }
        self.init(rawValue: fieldValue)
    }
}
