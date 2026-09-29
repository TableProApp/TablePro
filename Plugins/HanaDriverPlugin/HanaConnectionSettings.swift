import Foundation
import TableProPluginKit

enum HanaConnectionSettings {
    static func configuredSchema(in config: DriverConnectionConfig) -> String? {
        nonEmpty(config.database)
    }

    static func configuration(from config: DriverConnectionConfig) throws -> HanaConnectConfiguration {
        guard let host = nonEmpty(config.host) else {
            throw HanaError(kind: .configuration, message: String(localized: "Enter the SAP HANA host name."))
        }
        guard (1...65_535).contains(config.port) else {
            throw HanaError(kind: .configuration, message: String(localized: "The SAP HANA port must be between 1 and 65535."))
        }
        guard !config.username.isEmpty else {
            throw HanaError(kind: .configuration, message: String(localized: "Enter the SAP HANA user name."))
        }
        let usesTLS = config.ssl.mode != .disabled
        let certificatePath = usesTLS ? nonEmpty(config.ssl.clientCertificatePath) ?? "" : ""
        let keyPath = usesTLS ? nonEmpty(config.ssl.clientKeyPath) ?? "" : ""
        guard certificatePath.isEmpty == keyPath.isEmpty else {
            throw HanaError(
                kind: .configuration,
                message: String(localized: "Set both a client certificate and a client key, or neither.")
            )
        }
        return HanaConnectConfiguration(
            host: host,
            port: config.port,
            username: config.username,
            password: config.password,
            schema: configuredSchema(in: config) ?? "",
            tlsMode: HanaConnectConfiguration.TLSMode(config.ssl.mode),
            tlsServerName: usesTLS ? nonEmpty(config.additionalFields[HanaMetadata.tlsServerNameField]) ?? "" : "",
            caCertificatePath: usesTLS ? nonEmpty(config.ssl.caCertificatePath) ?? "" : "",
            clientCertificatePath: certificatePath,
            clientKeyPath: keyPath,
            connectTimeoutSeconds: HanaConnectConfiguration.connectTimeoutSeconds
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
