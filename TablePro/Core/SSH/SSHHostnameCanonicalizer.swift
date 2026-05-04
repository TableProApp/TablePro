//
//  SSHHostnameCanonicalizer.swift
//  TablePro
//

import Darwin
import Foundation
import os

struct SSHCanonicalizationOptions: Sendable, Hashable {
    let mode: CanonicalizeMode
    let domains: [String]
    let fallbackLocal: Bool
    let maxDots: Int
    let permittedCNAMEs: String?

    static let disabled = SSHCanonicalizationOptions(
        mode: .no,
        domains: [],
        fallbackLocal: true,
        maxDots: 1,
        permittedCNAMEs: nil
    )
}

enum SSHHostnameCanonicalizer {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHCanonicalize")

    /// Returns nil only when no `CanonicalDomains` candidate resolves AND
    /// `CanonicalizeFallbackLocal` is set to `no`. The caller treats nil as
    /// "abort canonicalization" per ssh_config(5).
    static func canonicalize(
        host: String,
        options: SSHCanonicalizationOptions,
        resolver: (String) -> String? = defaultResolver
    ) -> String? {
        guard options.mode != .no else { return host }
        guard !host.isEmpty else { return host }

        if dotCount(in: host) > options.maxDots {
            return host
        }

        for domain in options.domains {
            let candidate = host + "." + domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let canonical = resolver(candidate) {
                logger.debug("Canonicalized \(host, privacy: .public) -> \(canonical, privacy: .public)")
                return canonical
            }
        }

        if options.fallbackLocal {
            return host
        }
        return nil
    }

    private static func dotCount(in host: String) -> Int {
        host.reduce(0) { $1 == "." ? $0 + 1 : $0 }
    }

    static func defaultResolver(_ candidate: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_CANONNAME

        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(candidate, nil, &hints, &result)
        guard rc == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(info) }

        if let canonName = info.pointee.ai_canonname {
            return String(cString: canonName)
        }
        return candidate
    }
}
