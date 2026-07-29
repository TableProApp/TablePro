import Foundation
import TableProModels

struct DriverSSLConfiguration: Equatable, Sendable {
    let mode: SSLConfiguration.SSLMode
    let caCertificatePath: String?

    static let disabled = DriverSSLConfiguration(mode: .disable)

    init(mode: SSLConfiguration.SSLMode, caCertificatePath: String? = nil) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
    }

    init(sslEnabled: Bool, configuration: SSLConfiguration?) {
        guard let configuration else {
            mode = sslEnabled ? .require : .disable
            caCertificatePath = nil
            return
        }
        mode = configuration.mode
        caCertificatePath = configuration.caCertificatePath
    }

    var isEnabled: Bool { mode != .disable }
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyFull }
    var verifiesHostname: Bool { mode == .verifyFull }

    var postgresSSLMode: String {
        switch mode {
        case .disable: return "disable"
        case .require: return "require"
        case .verifyCa: return "verify-ca"
        case .verifyFull: return "verify-full"
        }
    }

    var freetdsEncryptionFlag: String {
        switch mode {
        case .disable: return "off"
        case .require, .verifyCa, .verifyFull: return "require"
        }
    }

    var existingCACertificatePath: String? {
        guard verifiesCertificate,
              let path = caCertificatePath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }
}
