import Foundation
import TableProPluginKit

struct LibSQLError: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = LibSQLError(message: String(localized: "Not connected to database"))
}
