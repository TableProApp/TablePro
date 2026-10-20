//
//  SSHNegotiationFailure.swift
//  TableProSSHTransport
//

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

    public static func clientMethods(_ names: [String]) -> [String] {
        names.filter { !pseudoMethods.contains($0) }
    }

    // Extension negotiation and strict key exchange ride in the key exchange list but no server can pick them.
    private static let pseudoMethods: Set<String> = ["ext-info-c", "kex-strict-c-v00@openssh.com"]
}
