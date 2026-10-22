import Foundation
import TableProCoreTypes
import TableProKerberos
import TableProMySQLCore
import TableProPluginKit

// The server picks auth_gssapi_client for an account IDENTIFIED VIA gssapi, and the connector
// answers with the ticket in the credential cache.
struct MariaDBKerberosSignIn: Equatable, Sendable {
    // A private cache holding the ticket a principal and password requested; nil uses the
    // default cache. A kill connection signs in again, so it lives as long as the session.
    let cachePath: String?

    static func resolve(
        additionalFields: [String: String],
        deadline: MySQLConnectDeadline
    ) async throws -> MariaDBKerberosSignIn? {
        guard KerberosAuthFields.isSelected(in: additionalFields) else { return nil }
        let principal = (additionalFields[KerberosAuthFields.principalFieldId] ?? "")
            .trimmingCharacters(in: .whitespaces)
        let password = additionalFields[KerberosAuthFields.passwordFieldId] ?? ""
        guard !principal.isEmpty, !password.isEmpty else {
            return MariaDBKerberosSignIn(cachePath: nil)
        }
        guard let remaining = deadline.remainingMilliseconds() else {
            throw MariaDBPluginError.connectionTimedOut
        }
        do {
            let cachePath = try await KerberosTicket.acquire(
                principal: principal,
                password: password,
                timeoutMilliseconds: remaining,
                timeoutError: { MariaDBPluginError.connectionTimedOut }
            )
            return MariaDBKerberosSignIn(cachePath: cachePath)
        } catch KerberosTicketError.rejected(let kind, let message) {
            throw failure(kind: kind, serverMessage: message, code: 0)
        }
    }

    // Without a ticket the macOS GSS framework gives the connector no minor status, so its message
    // carries GSS_S_FAILURE (851968) alone. Measured with Connector/C 3.4.4.
    static func failureKind(for message: String) -> KerberosFailureKind? {
        if let kind = KerberosFailureClassifier.classify(message) {
            return kind
        }
        return message.contains("(major 851968, minor 0) : gss_init_sec_context") ? .noCredential : nil
    }

    static func failure(kind: KerberosFailureKind, serverMessage: String, code: UInt32) -> MariaDBPluginError {
        let message = KerberosFailureMessage.describe(
            kind: kind,
            serverMessage: serverMessage,
            spnNotFound: (
                summary: String(localized: "The MariaDB Kerberos service principal is not registered."),
                suggestion: String(localized: "Ask your administrator to register the name in the server's gssapi_principal_name setting, and connect by hostname rather than IP address.")
            )
        )
        return MariaDBPluginError(code: code, message: message, sqlState: nil)
    }
}
