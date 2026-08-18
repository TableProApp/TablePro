import Foundation
import TableProPluginKit

struct DamengError: Error, PluginDriverError, Sendable {
    let message: String

    var pluginErrorMessage: String { message }
}
