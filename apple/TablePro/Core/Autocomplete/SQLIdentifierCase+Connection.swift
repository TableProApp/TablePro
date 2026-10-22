import Foundation
import TableProAutocomplete

extension SQLIdentifierCase {
    // Read per request, so a changed setting applies to the next keystroke rather than the next connect.
    @MainActor
    static func stored(for connectionId: UUID?) -> SQLIdentifierCase {
        guard let connectionId else { return .default }
        return ConnectionStorage.shared.loadConnection(id: connectionId)?.completionIdentifierCase ?? .default
    }
}
