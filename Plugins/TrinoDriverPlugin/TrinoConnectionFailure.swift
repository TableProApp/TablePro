import Foundation
import TableProPluginKit
import TableProTrinoCore

extension TrinoError {
    var connectionFailure: Error {
        switch self {
        case .tlsHandshakeFailed(let kind, let serverMessage):
            return kind.sslHandshakeError(serverMessage: serverMessage)
        case .redirected(let statusCode, let location, let advice):
            return TrinoError.invalidConfiguration(Self.redirectAdvice(
                statusCode: statusCode,
                location: location,
                advice: advice
            ))
        case .credentialsRequireTLS(let kind):
            return kind.plaintextRefusal
        default:
            return self
        }
    }

    private static func redirectAdvice(statusCode: Int, location: String?, advice: TrinoRedirectAdvice) -> String {
        guard let location else {
            return String(
                format: String(
                    localized: """
                        The server answered with HTTP %lld and no address. Trino never redirects, so a proxy in \
                        front of it sent this. Check the host, port and SSL Mode.
                        """
                ),
                Int64(statusCode)
            )
        }
        switch advice {
        case .turnOnTLS(let port):
            return String(
                format: String(
                    localized: "The server redirected the request to %1$@, which needs HTTPS. Set Port to %2$lld and SSL Mode to Verify Identity."
                ),
                location,
                Int64(port)
            )
        case .checkAddress:
            return String(
                format: String(
                    localized: """
                        The server redirected the request to %@. TablePro does not follow redirects, and Trino never \
                        sends one, so a proxy in front of it did. Check the host, port and SSL Mode.
                        """
                ),
                location
            )
        }
    }
}
