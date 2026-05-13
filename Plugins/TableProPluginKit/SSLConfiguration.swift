import Foundation

public enum SSLMode: String, Codable, CaseIterable, Sendable {
    case disabled = "Disabled"
    case preferred = "Preferred"
    case required = "Required"
    case verifyCa = "Verify CA"
    case verifyIdentity = "Verify Identity"
}

public struct SSLConfiguration: Codable, Hashable, Sendable {
    public var mode: SSLMode
    public var caCertificatePath: String
    public var clientCertificatePath: String
    public var clientKeyPath: String

    public init(
        mode: SSLMode = .disabled,
        caCertificatePath: String = "",
        clientCertificatePath: String = "",
        clientKeyPath: String = ""
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    public var isEnabled: Bool { mode != .disabled }
    public var verifiesCertificate: Bool { mode == .verifyCa || mode == .verifyIdentity }
    public var verifiesHostname: Bool { mode == .verifyIdentity }
}
