import Foundation
import TableProTeradataCore

enum TeradataVersionProbe {
    /// The catalog can be ACL-restricted without making the established session unusable. Socket,
    /// protocol, timeout and cancellation failures instead invalidate the provisional connection.
    static func mayIgnore(_ error: Error) -> Bool {
        guard let wireError = error as? TeradataWireError else { return false }
        if case .server = wireError { return true }
        return false
    }
}
