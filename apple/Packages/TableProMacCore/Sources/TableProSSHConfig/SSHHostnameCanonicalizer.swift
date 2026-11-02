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

    // Nil only when no `CanonicalDomains` candidate resolves under `CanonicalizeFallbackLocal no`,
    // which the caller reports instead of connecting.
    static func canonicalize(
        host: String,
        options: SSHCanonicalizationOptions,
        resolver: (String) -> String? = defaultResolver
    ) -> String? {
        guard options.mode != .no else { return host }
        guard !host.isEmpty else { return host }
        guard !isNumericHost(host) else { return host }

        // An anchored name is looked up as it is, before MaxDots and the suffixes, as ssh does.
        if host.hasSuffix(".") {
            let candidate = String(host.dropLast())
            guard let resolved = resolver(candidate) else { return options.fallbackLocal ? host : nil }
            return followsCNAME(from: candidate, to: resolved, rules: options.permittedCNAMEs) ? resolved : candidate
        }

        if dotCount(in: host) > options.maxDots {
            return host
        }

        for domain in options.domains {
            let candidate = host + "." + domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let resolved = resolver(candidate) {
                let canonical = followsCNAME(from: candidate, to: resolved, rules: options.permittedCNAMEs)
                    ? resolved
                    : candidate
                logger.debug("Canonicalized \(host, privacy: .public) -> \(canonical, privacy: .public)")
                return canonical
            }
        }

        if options.fallbackLocal {
            return host
        }
        return nil
    }

    // check_follow_cname in ssh.c: the canonical name becomes the dialed host and the host key's
    // name, so DNS picks it only where a `source_list:target_list` rule, or a bare `*`, covers both.
    private static func followsCNAME(from candidate: String, to cname: String, rules: String?) -> Bool {
        guard let rules, !SSHConfigParser.isNone(rules), cname != candidate, isValidDomain(cname) else { return false }
        return rules.split(whereSeparator: { $0 == " " || $0 == "\t" }).contains { rule in
            if rule == "*" { return true }
            let lists = rule.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard lists.count == 2 else { return false }
            return matches(candidate, patternList: lists[0]) && matches(cname, patternList: lists[1])
        }
    }

    private static func matches(_ name: String, patternList: String) -> Bool {
        SSHHostPatternMatcher.matches(
            host: name,
            patterns: SSHHostPatternMatcher.parseMatchPatternList(patternList),
            caseSensitive: false
        )
    }

    // valid_domain in OpenSSH's misc.c, which ssh applies to a CNAME before using it.
    private static func isValidDomain(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard let first = scalars.first, isASCIIAlphanumeric(first) || first == "_" else { return false }
        for (index, scalar) in scalars.enumerated() {
            guard isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_" else { return false }
            if scalar == ".", index > 0, scalars[index - 1] == "." { return false }
        }
        return true
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
    }

    // getaddrinfo's numeric rules, as ssh's resolve_addr uses, so `127.1` and a scoped IPv6 count too.
    private static func isNumericHost(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_NUMERICHOST
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return false }
        freeaddrinfo(result)
        return true
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
        // Anchored as ssh does, or the resolver's search list could complete a name that does not exist.
        let rc = getaddrinfo(candidate + ".", nil, &hints, &result)
        guard rc == 0, let info = result else {
            return nil
        }
        defer { freeaddrinfo(info) }

        if let canonName = info.pointee.ai_canonname {
            let name = String(cString: canonName)
            return name.hasSuffix(".") ? String(name.dropLast()) : name
        }
        return candidate
    }
}
