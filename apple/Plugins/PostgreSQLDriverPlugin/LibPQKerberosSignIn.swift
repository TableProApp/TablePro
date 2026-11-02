import Foundation
import TableProCoreTypes
import TableProKerberos
import TableProPluginKit

struct LibPQKerberosSignIn: Equatable, Sendable {
    let gssEncryptionMode: String
    // A private cache holding the ticket a principal and password requested; nil uses the
    // default cache.
    let cachePath: String?

    static func gssEncryptionMode(in additionalFields: [String: String]) -> String {
        let value = additionalFields[KerberosAuthFields.gssEncryptionFieldId] ?? ""
        return KerberosAuthFields.gssEncryptionModes.contains(value) ? value : "prefer"
    }

    static func resolve(
        additionalFields: [String: String],
        timeoutMilliseconds: Int
    ) async throws -> LibPQKerberosSignIn? {
        guard KerberosAuthFields.isSelected(in: additionalFields) else { return nil }
        let mode = gssEncryptionMode(in: additionalFields)
        let principal = (additionalFields[KerberosAuthFields.principalFieldId] ?? "")
            .trimmingCharacters(in: .whitespaces)
        let password = additionalFields[KerberosAuthFields.passwordFieldId] ?? ""
        guard !principal.isEmpty, !password.isEmpty else {
            return LibPQKerberosSignIn(gssEncryptionMode: mode, cachePath: nil)
        }
        do {
            let cachePath = try await KerberosTicket.acquire(
                principal: principal,
                password: password,
                timeoutMilliseconds: timeoutMilliseconds,
                timeoutError: { LibPQPluginError.connectionTimedOut }
            )
            return LibPQKerberosSignIn(gssEncryptionMode: mode, cachePath: cachePath)
        } catch KerberosTicketError.rejected(let kind, let message) {
            throw failure(kind: kind, serverMessage: message)
        }
    }

    // Every other sign-in sends require_auth=!gss, so a server that wants Kerberos says so here.
    static func refusedForAnotherSignIn(_ message: String) -> LibPQPluginError? {
        guard message.contains("requirement \"!gss\" failed") else { return nil }
        return LibPQPluginError(
            message: String(localized: "This server signs in with Kerberos. Set Authentication to Kerberos (GSSAPI), then reconnect."),
            sqlState: nil,
            detail: message
        )
    }

    static func failure(kind: KerberosFailureKind, serverMessage: String) -> LibPQPluginError {
        let message = KerberosFailureMessage.describe(
            kind: kind,
            serverMessage: serverMessage,
            spnNotFound: (
                summary: String(localized: "The PostgreSQL Kerberos service principal is not registered."),
                suggestion: String(localized: "Ask your administrator to register postgres/host.domain.com in the realm, and connect by hostname rather than IP address.")
            )
        )
        return LibPQPluginError(message: message, sqlState: nil, detail: nil)
    }
}
