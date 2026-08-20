import Foundation
import TableProPluginKit

struct DamengError: Error, PluginDriverError, Sendable {
    let message: String

    /// The failure closed the DM8 connection rather than only rejecting the statement, so
    /// the driver reconnects before its next one instead of retrying against a handle that
    /// can never serve again.
    let closedConnection: Bool

    init(message: String, closedConnection: Bool = false) {
        self.message = message
        self.closedConnection = closedConnection
    }

    var pluginErrorMessage: String { message }
}
