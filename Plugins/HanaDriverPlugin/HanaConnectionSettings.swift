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
            connectTimeoutSeconds: connectTimeoutSeconds(in: config.additionalFields)
        )
    }

    private static func connectTimeoutSeconds(in fields: [String: String]) -> Double {
        if let milliseconds = positiveNumber(fields["connectTimeoutMilliseconds"]) {
            return max(0.001, milliseconds / 1_000)
        }
        if let seconds = positiveNumber(fields["connectTimeoutSeconds"]) {
            return seconds
        }
        return HanaConnectConfiguration.defaultConnectTimeoutSeconds
    }

    private static func positiveNumber(_ value: String?) -> Double? {
        guard let value,
              let number = Double(value),
              number > 0,
              number.isFinite else { return nil }
        return min(number, Double(Int32.max))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
