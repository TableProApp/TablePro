import Foundation

public struct SSHNegotiationFailure: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case keyExchangeOrHostKey
        case cipher
        case mac
        case undetermined
    }

    public let stage: Stage
    public let serverSoftware: String?
    public let supported: [String]
    public let supportedHostKeys: [String]

    public init(stage: Stage, serverSoftware: String?, supported: [String], supportedHostKeys: [String]) {
        self.stage = stage
        self.serverSoftware = serverSoftware
        self.supported = supported
        self.supportedHostKeys = supportedHostKeys
    }

    // libssh2 records a key exchange only once one with a usable host key agrees, so a nil one cannot tell the two apart.
    public static func stage(kex: String?, cipher: String?, mac: String?) -> Stage {
        if kex == nil { return .keyExchangeOrHostKey }
        if cipher == nil { return .cipher }
        if mac == nil { return .mac }
        return .undetermined
    }

    public static func serverSoftware(banner: String?) -> String? {
        guard let line = banner?.trimmingCharacters(in: .whitespacesAndNewlines), line.hasPrefix("SSH-") else {
            return nil
        }
        let fields = line.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }
        let software = fields[2].prefix { !$0.isWhitespace }
        return software.isEmpty ? nil : String(software)
    }

    public var explanation: String {
        var sentences: [String] = []

        switch stage {
        case .keyExchangeOrHostKey:
            sentences.append(String(localized: "TablePro and the SSH server have no key exchange or host key method in common."))
        case .cipher:
            sentences.append(String(localized: "TablePro and the SSH server have no cipher in common."))
        case .mac:
            sentences.append(String(localized: "TablePro and the SSH server have no MAC algorithm in common."))
        case .undetermined:
            sentences.append(String(localized: "TablePro and the SSH server could not agree on how to encrypt the connection."))
        }

        if let serverSoftware {
            sentences.append(String(format: String(localized: "The server runs %@."), serverSoftware))
        }

        if !supported.isEmpty {
            let list = supported.formatted(.list(type: .and))
            switch stage {
            case .keyExchangeOrHostKey:
                sentences.append(String(format: String(localized: "TablePro supports these key exchange methods: %@."), list))
            case .cipher:
                sentences.append(String(format: String(localized: "TablePro supports these ciphers: %@."), list))
            case .mac:
                sentences.append(String(format: String(localized: "TablePro supports these MAC algorithms: %@."), list))
            case .undetermined:
                break
            }
        }

        if !supportedHostKeys.isEmpty {
            sentences.append(String(
                format: String(localized: "It supports these host key types: %@."),
                supportedHostKeys.formatted(.list(type: .and))
            ))
        }

        return sentences.joined(separator: " ")
    }

    public static var recoverySuggestion: String {
        String(localized: "Ask the SSH server's administrator to turn on a method TablePro supports.")
    }

    public static func clientMethods(_ names: [String]) -> [String] {
        names.filter { !pseudoMethods.contains($0) }
    }

    // Extension negotiation and strict key exchange ride in the key exchange list but no server can pick them.
    private static let pseudoMethods: Set<String> = ["ext-info-c", "kex-strict-c-v00@openssh.com"]
}
