import Foundation
import TableProPluginKit

struct SSLModeNotSupportedError: Error, LocalizedError, Equatable {
    enum Reason: Equatable {
        case unsupported
        case unsupportedThroughTunnel
        case tunnelNamesNoServer
    }

    let mode: SSLMode
    let typeName: String
    let supportedModes: [SSLMode]
    var reason: Reason = .unsupported

    // A URL, an import or a sync can store a mode the driver's form never offers.
    static func refusal(for connection: DatabaseConnection, pluginType: any DriverPlugin.Type) -> SSLModeNotSupportedError? {
        guard pluginType.connectionMode == .network else { return nil }
        let mode = connection.transportSSLConfiguration.mode
        let supported = pluginType.supportedSSLModes
        guard supported.contains(mode) else {
            return SSLModeNotSupportedError(mode: mode, typeName: connection.type.displayName, supportedModes: supported)
        }
        return tunnelRefusal(for: connection, pluginType: pluginType)
    }

    // Through a loopback forward the driver checks the certificate against the pre-tunnel host, which a driver may not
    // be able to do and a blank host leaves nothing to check against.
    private static func tunnelRefusal(
        for connection: DatabaseConnection,
        pluginType: any DriverPlugin.Type
    ) -> SSLModeNotSupportedError? {
        guard connection.dialsTunnelTCPForward else { return nil }
        var tunneled = connection
        tunneled.sslConfig = connection.sslConfigurationThroughTunnel(listenerSecuresTransport: false)
        tunneled.additionalFields[DatabaseConnection.tunnelSecuresTransportKey] = nil
        let ssl = tunneled.transportSSLConfiguration
        let throughTunnel = pluginType.sslModesThroughTunnel
        guard throughTunnel.contains(ssl.mode) else {
            return SSLModeNotSupportedError(
                mode: ssl.mode,
                typeName: connection.type.displayName,
                supportedModes: throughTunnel,
                reason: .unsupportedThroughTunnel
            )
        }
        let serverHost = connection.tunnelForwardEndpoint.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ssl.verifiesCertificate, serverHost.isEmpty else { return nil }
        return SSLModeNotSupportedError(
            mode: ssl.mode,
            typeName: connection.type.displayName,
            supportedModes: throughTunnel.filter { !SSLConfiguration(mode: $0).verifiesCertificate },
            reason: .tunnelNamesNoServer
        )
    }

    var errorDescription: String? {
        let alternatives = supportedModes.map(\.displayLabel).formatted(.list(type: .or))
        switch reason {
        case .unsupported:
            return String(
                format: String(localized: "This connection uses SSL Mode %2$@, which the %1$@ driver does not support. It supports %3$@."),
                typeName,
                mode.displayLabel,
                alternatives
            )
        case .unsupportedThroughTunnel where driverMayAddMode:
            return String(
                format: String(
                    localized: """
                        The %1$@ driver cannot use SSL Mode %2$@ through a tunnel. A newer version of the driver may \
                        support it. Until then, choose %3$@, or connect without the tunnel.
                        """
                ),
                typeName,
                mode.displayLabel,
                alternatives
            )
        case .unsupportedThroughTunnel:
            return String(
                format: String(
                    localized: """
                        The %1$@ driver cannot use SSL Mode %2$@ through a tunnel. Through a tunnel it supports %3$@. \
                        Choose one of those, or connect without the tunnel.
                        """
                ),
                typeName,
                mode.displayLabel,
                alternatives
            )
        case .tunnelNamesNoServer:
            return String(
                format: String(
                    localized: """
                        SSL Mode %1$@ checks the certificate of the server behind the tunnel, and this connection \
                        leaves that server's host blank. Enter the host the tunnel reaches, or set SSL Mode to %2$@.
                        """
                ),
                mode.displayLabel,
                alternatives
            )
        }
    }

    // PluginKit's default means the driver never said what it keeps through a tunnel, so a newer build may add a mode.
    var driverMayAddMode: Bool {
        reason == .unsupportedThroughTunnel && supportedModes == [.disabled, .preferred, .required]
    }
}

extension SSLModeNotSupportedError: ConnectionPreflightReporting {
    var failedBeforeDialing: Bool { true }
}
