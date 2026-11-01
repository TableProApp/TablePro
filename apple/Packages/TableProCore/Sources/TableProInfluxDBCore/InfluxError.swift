import Foundation

public enum InfluxError: Error, Equatable, LocalizedError {
    case notConnected
    case invalidURL(String)
    case unauthorized(String)
    case server(status: Int, message: String)
    case query(String)
    case malformedResponse(String)
    case missingDatabase
    case missingOrganization
    case filterNotExpressible(InfluxQueryLanguage)
    case multipleStatements
    case fluxReadDiffers
    case unknownVersion
    case unsupportedVersion(String)
    case unsupportedLanguage(InfluxQueryLanguage, generation: InfluxGeneration)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to InfluxDB.")
        case .invalidURL(let text):
            return String(format: String(localized: "Invalid InfluxDB address: %@"), text)
        case .unauthorized(let message):
            return message.isEmpty
                ? String(localized: "InfluxDB refused the token.")
                : String(format: String(localized: "InfluxDB refused the token: %@"), message)
        case .server(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .query(let message):
            return message
        case .malformedResponse(let detail):
            return String(format: String(localized: "Unexpected InfluxDB response: %@"), detail)
        case .missingDatabase:
            return String(localized: "Choose a database or bucket first.")
        case .missingOrganization:
            return String(localized: "InfluxDB 2 needs an organization. Set it in the connection settings.")
        case .filterNotExpressible(let language):
            return String(
                format: String(localized: "%@ cannot run this filter on that column."),
                language.displayName
            )
        case .multipleStatements:
            return String(localized: "Run one InfluxQL statement at a time, with no ; inside it.")
        case .fluxReadDiffers:
            return String(
                localized: "InfluxDB reads this Flux script as one that writes or reaches outside the database, which TablePro's check did not see, so it was not run."
            )
        case .unknownVersion:
            return String(localized: "The server did not say which InfluxDB version it runs.")
        case .unsupportedVersion(let version):
            return String(format: String(localized: "InfluxDB %@ is not supported. Connect to InfluxDB 2 or 3."), version)
        case .unsupportedLanguage(let language, let generation):
            return String(
                format: String(localized: "%@ is not available on this server. It accepts %@."),
                language.displayName,
                generation.languages.map(\.displayName).joined(separator: ", ")
            )
        }
    }
}
