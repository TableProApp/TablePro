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
        case .unsupportedLanguage(let language, let generation):
            let available = generation.languages.map(\.displayName).joined(separator: ", ")
            return String(
                format: String(localized: "%@ is not available on this server. It accepts %@."),
                language.displayName,
                available
            )
        }
    }
}
