//
//  OracleDiagnosticSheet.swift
//  TablePro
//

import AppKit
import SwiftUI

struct OracleDiagnosticPayload: Identifiable, Equatable {
    let id = UUID()
    let host: String
    let port: Int
    let serviceOrDatabase: String
    let username: String
    let errorMessage: String
    let category: Category

    enum Category: Equatable {
        case unsupportedVerifier
        case uncleanShutdown
        case serverVersionNotSupported
        case generic

        var title: String {
            switch self {
            case .unsupportedVerifier:
                return String(localized: "Unsupported Password Verifier")
            case .uncleanShutdown:
                return String(localized: "Connection Dropped During Handshake")
            case .serverVersionNotSupported:
                return String(localized: "Server Version Not Supported")
            case .generic:
                return String(localized: "Connection Test Failed")
            }
        }

        var actions: [String] {
            switch self {
            case .unsupportedVerifier:
                return [
                    String(localized: "Verify the user account exists and the password is correct."),
                    String(localized: "Ask your DBA to confirm the user has an 11G or 12C password verifier (SELECT password_versions FROM dba_users WHERE username = '<USER>')."),
                    String(localized: "If the verifier is brand-new (e.g. 23ai), file an issue at github.com/TableProApp/TablePro/issues with the verifier flag shown below."),
                ]
            case .uncleanShutdown:
                return [
                    String(localized: "If the same connection works in DBeaver or sqlplus, this is likely an OOB compatibility issue with cloud-hosted Oracle."),
                    String(localized: "TablePro v1.2.0 already gates OOB on the server flag, so most cases are resolved. If you still hit this, file an issue at github.com/TableProApp/TablePro/issues/483."),
                    String(localized: "Try disabling SSH tunnel or load balancer firewall rules between client and server."),
                ]
            case .serverVersionNotSupported:
                return [
                    String(localized: "TablePro requires Oracle 12c or later via the OracleNIO Swift driver."),
                    String(localized: "Check the user account's password_versions; only 11G and 12C are supported."),
                    String(localized: "Rotate the password under modern auth if password_versions includes only 10G."),
                ]
            case .generic:
                return [
                    String(localized: "Verify host, port, service name, and credentials match a working client."),
                    String(localized: "Check the listener is reachable: lsnrctl status."),
                    String(localized: "If you are confident the connection works in DBeaver / sqlplus, file an issue."),
                ]
            }
        }
    }
}

struct OracleDiagnosticSheet: View {
    let payload: OracleDiagnosticPayload
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(payload.category.title, systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Text(payload.errorMessage)
                .font(.system(.body, design: .default))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Suggested Actions"))
                    .font(.subheadline.weight(.semibold))
                ForEach(Array(payload.category.actions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                        Text(action)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Diagnostic Info"))
                    .font(.subheadline.weight(.semibold))
                Text(diagnosticBlock)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
            }

            HStack {
                Button(String(localized: "Copy Diagnostic Info")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticBlock, forType: .string)
                }
                Button(String(localized: "Open Issue Tracker")) {
                    if let url = URL(string: "https://github.com/TableProApp/TablePro/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button(String(localized: "Close"), action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    private var diagnosticBlock: String {
        """
        Host:    \(payload.host)
        Port:    \(payload.port)
        Service: \(payload.serviceOrDatabase)
        User:    \(payload.username)
        Error:   \(payload.errorMessage)
        """
    }
}
