//
//  SSLPaneViewModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

@MainActor
final class SSLPaneViewModel: ObservableObject {
    @Published private(set) var mode: SSLMode = .disabled
    private(set) var origin: SSLModeOrigin = .typeDefault
    @Published var caCertPath: String = ""
    @Published var clientCertPath: String = ""
    @Published var clientKeyPath: String = ""
    @Published var clientKeyPassphrase: String = ""

    @Published var coordinator: WeakCoordinatorRef?

    /// Silent on a driver that renders no SSL section, so a stored mode the form cannot show
    /// cannot disable Save over a certificate field the user has no way to reach.
    var validationIssues: [String] {
        guard coordinator?.value?.supportsSSL ?? true else { return [] }
        let type = coordinator?.value?.network.type
        guard type?.supportsPerConnectionCertificatePaths ?? true else { return [] }
        var issues: [String] = []
        let requiresCA = type?.requiresCACertificate(for: mode) ?? (mode == .verifyCa || mode == .verifyIdentity)
        if requiresCA, caCertPath.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(String(localized: "CA certificate is required for verification modes"))
        }
        let hasClientCert = !clientCertPath.trimmingCharacters(in: .whitespaces).isEmpty
        let hasClientKey = !clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty
        if hasClientCert && !hasClientKey {
            issues.append(String(localized: "Client key is required when client certificate is set"))
        }
        return issues
    }

    func select(_ newMode: SSLMode) {
        mode = newMode
        origin = .chosen
    }

    func applyImported(_ resolution: SSLModeResolution) {
        apply(resolution)
    }

    func reconcile(port: Int, type: DatabaseType) {
        guard origin != .chosen else { return }
        apply(type.sslModeResolution(forPort: port))
    }

    private func apply(_ resolution: SSLModeResolution) {
        guard resolution != SSLModeResolution(mode: mode, origin: origin) else { return }
        mode = resolution.mode
        origin = resolution.origin
    }

    func load(from connection: DatabaseConnection) {
        mode = connection.sslConfig.mode
        origin = mode == connection.type.defaultSSLMode ? .typeDefault : .chosen
        caCertPath = connection.sslConfig.caCertificatePath
        clientCertPath = connection.sslConfig.clientCertificatePath
        clientKeyPath = connection.sslConfig.clientKeyPath
        clientKeyPassphrase = ConnectionStorage.shared.loadSSLClientKeyPassphrase(for: connection.id) ?? ""
    }

    func resetForType(_ type: DatabaseType) {
        mode = type.defaultSSLMode
        origin = .typeDefault
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
