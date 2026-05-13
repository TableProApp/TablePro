import Foundation
import TableProPluginKit

struct RedisSSLConfig {
    let mode: SSLMode
    let caCertificatePath: String
    let clientCertificatePath: String
    let clientKeyPath: String

    init(_ ssl: SSLConfiguration = SSLConfiguration()) {
        self.mode = ssl.mode
        self.caCertificatePath = ssl.caCertificatePath
        self.clientCertificatePath = ssl.clientCertificatePath
        self.clientKeyPath = ssl.clientKeyPath
    }

    var isEnabled: Bool { mode != .disabled }
    var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyIdentity }
    var verifiesHostname: Bool { mode == .verifyIdentity }
}
