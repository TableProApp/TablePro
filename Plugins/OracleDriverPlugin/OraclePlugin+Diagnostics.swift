//
//  OraclePlugin+Diagnostics.swift
//  TablePro
//

import Foundation
import TableProOracleCore
import TableProPluginKit

extension OraclePlugin {
    func diagnose(error: Error) -> PluginDiagnostic? {
        guard let oracleError = (error as? OraclePluginError)?.core else { return nil }
        let message = oracleError.errorDescription ?? ""
        let issuesURL = URL(string: "https://github.com/TableProApp/TablePro/issues")
        switch oracleError {
        case .authVerifierUnsupported(let flag):
            return PluginDiagnostic(
                title: String(localized: "Unsupported Password Verifier"),
                message: message,
                suggestedActions: [
                    String(localized: "Verify the user account exists and the password is correct."),
                    String(localized: "Ask your DBA to confirm the user has an 11G or 12C password verifier (SELECT password_versions FROM dba_users WHERE username = '<USER>')."),
                    String(localized: "If the verifier is brand-new (e.g. 23ai), file an issue with the verifier flag below.")
                ],
                diagnosticInfo: [
                    DiagnosticEntry(label: "Verifier flag", value: flag)
                ],
                supportURL: issuesURL
            )
        case .authConnectionDropped(let phase):
            return PluginDiagnostic(
                title: String(localized: "Connection Dropped During Handshake"),
                message: message,
                suggestedActions: [
                    String(localized: "Check for a firewall, VPN, or load balancer between you and the server that closes connections mid-handshake."),
                    String(localized: "If the listener endpoint is TLS-only (TCPS), set the SSL mode in the connection's SSL settings."),
                    String(localized: "Confirm the host and port reach the database listener directly, not a proxy that resets unknown traffic."),
                    String(localized: "If this is Oracle 11g, open an issue and include the handshake phase shown below.")
                ],
                diagnosticInfo: phase.map { [DiagnosticEntry(label: String(localized: "Handshake phase"), value: $0)] } ?? [],
                supportURL: URL(string: "https://github.com/TableProApp/TablePro/issues/483")
            )
        case .authVersionNotSupported:
            return PluginDiagnostic(
                title: String(localized: "Server Version Not Supported"),
                message: message,
                suggestedActions: [
                    String(localized: "TablePro supports Oracle Database 11.1 and later. This server reports an older release (10g or earlier)."),
                    String(localized: "Upgrade the database to 11.2 or later, or connect with a client that bundles Oracle's OCI client such as SQL Developer or DataGrip.")
                ],
                supportURL: issuesURL
            )
        case .protocolError:
            return PluginDiagnostic(
                title: String(localized: "Connection Reset"),
                message: message,
                suggestedActions: [
                    String(localized: "Run the query again. TablePro reconnects to the server automatically."),
                    String(localized: "If the same query keeps failing, the server may be returning data the driver cannot decode. File an issue with your Oracle version.")
                ],
                supportURL: URL(string: "https://github.com/TableProApp/TablePro/issues/483")
            )
        case .nativeEncryptionFailed:
            return PluginDiagnostic(
                title: String(localized: "Native Network Encryption Not Completed"),
                message: message,
                suggestedActions: [
                    String(localized: "The server requires Oracle native network encryption, and negotiating it with this server did not complete."),
                    String(localized: "Ask the DBA which encryption and checksum algorithms the server requires. The driver supports AES with a SHA-2 checksum."),
                    String(localized: "File an issue with your Oracle version and the details below so the driver can add support.")
                ],
                supportURL: issuesURL
            )
        case .loginTimedOut, .loginHandshakeStalled:
            return PluginDiagnostic(
                title: String(localized: "Login Handshake Timed Out"),
                message: message,
                suggestedActions: [
                    String(localized: "Confirm the host and port reach the database listener directly."),
                    String(localized: "If the server stopped answering at the network encryption step, set Network Encryption to Rejected on the Advanced tab and connect again."),
                    String(localized: "Check for a firewall, VPN, or proxy between you and the server that stalls connections after the TCP handshake."),
                    String(localized: "File an issue with your Oracle version and the step named above.")
                ],
                supportURL: issuesURL
            )
        case .nativeEncryptionRequired:
            return PluginDiagnostic(
                title: String(localized: "Native Network Encryption Required"),
                message: message,
                suggestedActions: [
                    String(localized: "Ask the DBA to allow Native Network Encryption for this client, or to turn it off for this connection."),
                    String(localized: "TLS is the alternative: set an SSL mode instead of relying on native network encryption.")
                ],
                supportURL: issuesURL
            )
        case .queryTimedOut:
            return PluginDiagnostic(
                title: String(localized: "Query Timed Out"),
                message: message,
                suggestedActions: [
                    String(localized: "Run the query again. TablePro reconnects to the server automatically."),
                    String(localized: "If the query legitimately needs more time, raise the query timeout in Settings > General."),
                    String(localized: "If a metadata query timed out, the schema may hold a very large number of objects; try again once the server is less busy.")
                ],
                supportURL: issuesURL
            )
        case .certificateUnavailable:
            return PluginDiagnostic(
                title: String(localized: "Certificate Not Available"),
                message: message,
                suggestedActions: [
                    String(localized: "Check the certificate paths in the connection's SSL settings."),
                    String(localized: "Certificate files are not part of a synced connection, so a connection set up on another device needs its certificates added here.")
                ],
                supportURL: issuesURL
            )
        case .notConnected, .connectionFailed, .queryFailed, .cancelled, .tlsHandshakeFailed,
             .transactionLost:
            return nil
        }
    }
}
