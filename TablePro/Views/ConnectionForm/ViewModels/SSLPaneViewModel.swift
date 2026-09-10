//
//  SSLPaneViewModel.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@Observable
@MainActor
final class SSLPaneViewModel {
    var mode: SSLMode = .disabled
    var caCertPath: String = ""
    var clientCertPath: String = ""
    var clientKeyPath: String = ""
    var clientKeyPassphrase: String = ""

    var coordinator: WeakCoordinatorRef?

    /// Silent on a driver that renders no SSL section, so a stored mode the form cannot show
    /// cannot disable Save over a certificate field the user has no way to reach.
    var validationIssues: [String] {
        guard coordinator?.value?.supportsSSL ?? true else { return [] }
        var issues: [String] = []
        if mode == .verifyCa || mode == .verifyIdentity {
            if caCertPath.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(String(localized: "CA certificate is required for verification modes"))
            }
        }
        let hasClientCert = !clientCertPath.trimmingCharacters(in: .whitespaces).isEmpty
        let hasClientKey = !clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        if hasClientCert && !hasClientKey {
            issues.append(String(localized: "Client key is required when client certificate is set"))
        }
        return issues
    }

    func load(from connection: DatabaseConnection) {
        mode = connection.sslConfig.mode
        caCertPath = connection.sslConfig.caCertificatePath
        clientCertPath = connection.sslConfig.clientCertificatePath
        clientKeyPath = connection.sslConfig.clientKeyPath
        clientKeyPassphrase = ConnectionStorage.shared.loadSSLClientKeyPassphrase(for: connection.id) ?? ""
    }

    func resetForType(_ type: DatabaseType) {
        mode = type.defaultSSLMode
        caCertPath = ""
        clientCertPath = ""
        clientKeyPath = ""
        clientKeyPassphrase = ""
    }

    func buildConfig() -> SSLConfiguration {
        SSLConfiguration(
            mode: mode,
            caCertificatePath: caCertPath,
            clientCertificatePath: clientCertPath,
            clientKeyPath: clientKeyPath
        )
    }
}
