import Foundation

public struct SSHNegotiationFailure: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case keyExchangeOrHostKey
        case cipher
        case mac
        // Public key sign-in, where the key's signature algorithm is agreed (RFC 8332, RFC 8308).
        case keySignature
        case undetermined
    }

    public let stage: Stage
    public let serverSoftware: String?
    public let supported: [String]
    public let supportedHostKeys: [String]
    // What the server offered for the stage; empty when its KEXINIT could not be read.
    public let offered: [String]
    public let offeredHostKeys: [String]

    public init(
        stage: Stage,
        serverSoftware: String?,
        supported: [String],
        supportedHostKeys: [String],
        proposal: SSHServerProposal? = nil
    ) {
        self.stage = stage
        self.serverSoftware = serverSoftware
        self.supported = supported
        self.supportedHostKeys = supportedHostKeys

        var offered: [String] = []
        var offeredHostKeys: [String] = []
        if let proposal {
            switch stage {
            case .keyExchangeOrHostKey:
                offered = Self.withoutPseudoMethods(proposal.keyExchange)
                offeredHostKeys = Self.unique(proposal.hostKeys)
            case .cipher:
                offered = Self.unmatched(proposal.ciphersClientToServer, proposal.ciphersServerToClient, supported: supported)
            case .mac:
                offered = Self.unmatched(proposal.macsClientToServer, proposal.macsServerToClient, supported: supported)
            case .keySignature, .undetermined:
                break
            }
        }
        self.offered = offered
        self.offeredHostKeys = offeredHostKeys
    }

    // libssh2 fails before sending anything when no signature algorithm it makes for the key is one
    // the server's server-sig-algs lists, or when the key type has no signer at all.
    public static func keySignature(serverBanner: String?) -> SSHNegotiationFailure {
        SSHNegotiationFailure(
            stage: .keySignature,
            serverSoftware: serverSoftware(banner: serverBanner),
            supported: [],
            supportedHostKeys: []
        )
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
        // RFC 4253, 4.2: printable US-ASCII, so a control or bidi character the server sends ends it.
        let software = fields[2].unicodeScalars.prefix { (0x21 ... 0x7E).contains($0.value) }
        return software.isEmpty ? nil : String(String.UnicodeScalarView(software))
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
        case .keySignature:
            sentences.append(String(localized: "TablePro and the SSH server have no signature algorithm in common for this key."))
        case .undetermined:
            sentences.append(String(localized: "TablePro and the SSH server could not agree on how to encrypt the connection."))
        }

        if let serverSoftware {
            sentences.append(String(format: String(localized: "The server runs %@."), serverSoftware))
        }

        sentences.append(contentsOf: retiredOffers)

        if stage == .keySignature {
            sentences.append(String(localized: "TablePro signs RSA keys with rsa-sha2-256 or rsa-sha2-512, not with ssh-rsa, which uses SHA-1."))
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
            case .keySignature, .undetermined:
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

    public static func withoutPseudoMethods(_ names: [String]) -> [String] {
        unique(names).filter { !pseudoMethods.contains($0) }
    }

    // A server can repeat a name any number of times in its KEXINIT.
    private static func unique(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    // Extension negotiation and strict key exchange ride in the key exchange list but no side can pick them.
    private static let pseudoMethods: Set<String> = [
        "ext-info-c", "ext-info-s", "kex-strict-c-v00@openssh.com", "kex-strict-s-v00@openssh.com",
    ]

    // What libssh2 1.11.1 in TablePro 0.83.0-beta.1 offered and the bundled libssh2 does not.
    // apple/scripts/probes/check-libssh2-algorithms.sh prints the difference.
    private static let retired: Set<String> = [
        "diffie-hellman-group1-sha1", "diffie-hellman-group14-sha1", "diffie-hellman-group-exchange-sha1",
        "ssh-rsa", "ssh-rsa-cert-v01@openssh.com",
        "3des-cbc", "blowfish-cbc", "cast128-cbc", "arcfour", "arcfour128",
        "hmac-sha1", "hmac-sha1-96", "hmac-sha1-etm@openssh.com", "hmac-md5", "hmac-md5-96",
        "hmac-ripemd160", "hmac-ripemd160@openssh.com",
    ]

    private var retiredOffers: [String] {
        switch stage {
        case .keyExchangeOrHostKey:
            var sentences: [String] = []
            if let list = Self.onlyRetired(offered) {
                sentences.append(String(
                    format: String(localized: "The server offers only key exchange methods TablePro no longer supports: %@."),
                    list
                ))
            }
            if let list = Self.onlyRetired(offeredHostKeys) {
                sentences.append(String(
                    format: String(localized: "The server offers only host key types TablePro no longer supports: %@."),
                    list
                ))
            }
            return sentences
        case .cipher:
            return Self.onlyRetired(offered).map {
                [String(format: String(localized: "The server offers only ciphers TablePro no longer supports: %@."), $0)]
            } ?? []
        case .mac:
            return Self.onlyRetired(offered).map {
                [String(format: String(localized: "The server offers only MAC algorithms TablePro no longer supports: %@."), $0)]
            } ?? []
        case .keySignature, .undetermined:
            return []
        }
    }

    private static func onlyRetired(_ offered: [String]) -> String? {
        guard !offered.isEmpty, offered.allSatisfy(retired.contains) else { return nil }
        return offered.formatted(.list(type: .and))
    }

    // libssh2 agrees each direction on its own, so the one with nothing in common is the one that failed.
    private static func unmatched(_ clientToServer: [String], _ serverToClient: [String], supported: [String]) -> [String] {
        let common = Set(supported)
        if !serverToClient.contains(where: common.contains), clientToServer.contains(where: common.contains) {
            return unique(serverToClient)
        }
        return unique(clientToServer)
    }
}
