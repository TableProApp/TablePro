import Foundation

public struct OracleTLSDescription: Sendable, Equatable {
    public enum Mode: Sendable, Equatable {
        case disabled
        case required
        case verifyCA
        case verifyIdentity
    }

    public var mode: Mode
    public var caCertificatePath: String?
    public var clientCertificatePath: String?
    public var clientKeyPath: String?

    public init(
        mode: Mode = .disabled,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.mode = mode
        self.caCertificatePath = Self.normalized(caCertificatePath)
        self.clientCertificatePath = Self.normalized(clientCertificatePath)
        self.clientKeyPath = Self.normalized(clientKeyPath)
    }

    public var verifiesCertificate: Bool { mode == .verifyCA || mode == .verifyIdentity }

    private static func normalized(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
