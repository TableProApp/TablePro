import Foundation
import TableProPluginKit

struct SSLModeNotSupportedError: Error, LocalizedError, Equatable {
    let mode: SSLMode
    let typeName: String
    let supportedModes: [SSLMode]

    // A URL, an import or a sync can store a mode the driver's form never offers.
    static func refusal(for connection: DatabaseConnection, pluginType: any DriverPlugin.Type) -> SSLModeNotSupportedError? {
        guard pluginType.connectionMode == .network else { return nil }
        let mode = connection.transportSSLConfiguration.mode
        let supported = pluginType.supportedSSLModes
        guard !supported.contains(mode) else { return nil }
        return SSLModeNotSupportedError(mode: mode, typeName: connection.type.displayName, supportedModes: supported)
    }

    var errorDescription: String? {
        String(
            format: String(localized: "This connection uses SSL Mode %2$@, which the %1$@ driver does not support. It supports %3$@."),
            typeName,
            mode.displayLabel,
            supportedModes.map(\.displayLabel).formatted(.list(type: .or))
        )
    }
}

extension SSLModeNotSupportedError: ConnectionPreflightReporting {
    var failedBeforeDialing: Bool { true }
}
