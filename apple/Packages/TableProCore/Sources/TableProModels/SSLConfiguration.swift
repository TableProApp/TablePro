import Foundation
import TableProPluginKit

public struct SSLConfiguration: Codable, Hashable, Sendable {
    public var mode: SSLMode {
        didSet {
            guard mode != oldValue else { return }
            isMacPreferred = false
            isLegacyRequire = false
        }
    }
    public var caCertificatePath: String?
    public var clientCertificatePath: String?
    public var clientKeyPath: String?
    // The Mac's Preferred falls back to plaintext. iOS has no such mode and opens it as .require, but writes Preferred back.
    public private(set) var isMacPreferred: Bool
    // iOS builds before the Mac's mode names stored the Mac's Preferred as "require", so such a copy cannot say which
    // of the two the Mac holds. Only the device's own library file keeps that spelling; everything else writes Required.
    public private(set) var isLegacyRequire: Bool

    public enum SSLMode: String, Codable, Sendable {
        case disable
        case require
        case verifyCa
        case verifyFull

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "disable", "Disabled": self = .disable
            case "require", "Required", "Preferred": self = .require
            case "verifyCa", "Verify CA": self = .verifyCa
            case "verifyFull", "Verify Identity": self = .verifyFull
            default: self = .disable
            }
        }

        fileprivate var macMode: TableProPluginKit.SSLMode {
            switch self {
            case .disable: .disabled
            case .require: .required
            case .verifyCa: .verifyCa
            case .verifyFull: .verifyIdentity
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case mode, caCertificatePath, clientCertificatePath, clientKeyPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(SSLMode.self, forKey: .mode)) ?? .disable
        let rawMode = try? container.decode(String.self, forKey: .mode)
        isMacPreferred = rawMode == TableProPluginKit.SSLMode.preferred.rawValue
        isLegacyRequire = rawMode == SSLMode.require.rawValue
        caCertificatePath = Self.path(in: container, forKey: .caCertificatePath)
        clientCertificatePath = Self.path(in: container, forKey: .clientCertificatePath)
        clientKeyPath = Self.path(in: container, forKey: .clientKeyPath)
    }

    // The Mac decodes this as TableProPluginKit.SSLConfiguration and skips a record it cannot read: its mode
    // names, and every path key, an unset one as "".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let keepsLegacySpelling = isLegacyRequire && encoder.userInfo[.deviceLibraryFile] as? Bool == true
        try container.encode(keepsLegacySpelling ? SSLMode.require.rawValue : macMode.rawValue, forKey: .mode)
        try container.encode(caCertificatePath ?? "", forKey: .caCertificatePath)
        try container.encode(clientCertificatePath ?? "", forKey: .clientCertificatePath)
        try container.encode(clientKeyPath ?? "", forKey: .clientKeyPath)
    }

    public init(
        mode: SSLMode = .disable,
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil,
        isMacPreferred: Bool = false
    ) {
        self.mode = mode
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
        self.isMacPreferred = isMacPreferred && mode == .require
        self.isLegacyRequire = false
    }

    // Same mode and paths, and the same Preferred, except that a copy an older iOS build stored takes the server's.
    public func agrees(withServer server: SSLConfiguration) -> Bool {
        let preferredAgrees = server.isMacPreferred == isMacPreferred || (server.isMacPreferred && isLegacyRequire)
        return preferredAgrees
            && server.mode == mode
            && server.caCertificatePath == caCertificatePath
            && server.clientCertificatePath == clientCertificatePath
            && server.clientKeyPath == clientKeyPath
    }

    public mutating func settleLegacyRequire(asMacPreferred macPreferred: Bool) {
        guard isLegacyRequire else { return }
        isLegacyRequire = false
        isMacPreferred = macPreferred
    }

    private var macMode: TableProPluginKit.SSLMode {
        isMacPreferred ? .preferred : mode.macMode
    }

    public static func isMacWireForm(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(TableProPluginKit.SSLConfiguration.self, from: data)) != nil
    }

    private static func path(in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        guard let value = try? container.decode(String.self, forKey: key), !value.isEmpty else { return nil }
        return value
    }
}

public extension CodingUserInfoKey {
    static let deviceLibraryFile: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "com.TablePro.deviceLibraryFile") else {
            preconditionFailure("CodingUserInfoKey refused a plain raw value")
        }
        return key
    }()
}
