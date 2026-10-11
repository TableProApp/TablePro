import Foundation
import TableProPluginKit

internal enum ClickHouseConnectFailure {
    static func error(for failure: Error, tlsRefusal: SSLHandshakeError?) -> Error {
        if let tlsRefusal {
            return tlsRefusal
        }
        if let serverAnswer = failure as? ClickHouseError {
            return serverAnswer
        }
        if let sslError = ClickHouseSSLClassifier.classifySSLError(failure) {
            return sslError
        }
        return ClickHouseError(message: String(
            format: String(localized: "Connection failed: %@"),
            failure.localizedDescription
        ))
    }
}
