//
//  SSHConfigDocument.swift
//  TablePro
//

import Foundation

struct SSHConfigDocument: Sendable, Hashable {
    let blocks: [SSHConfigBlock]
    let sourcePaths: [String]

    static let empty = SSHConfigDocument(blocks: [], sourcePaths: [])
}

struct SSHConfigBlock: Sendable, Hashable {
    let criteria: SSHConfigCriteria
    let directives: [SSHDirective]
}

enum SSHConfigCriteria: Sendable, Hashable {
    case global
    case host(patterns: [HostPattern])
    case match(conditions: [MatchCondition])
}

struct HostPattern: Sendable, Hashable {
    let glob: String
    let negated: Bool
}

enum MatchCondition: Sendable, Hashable {
    case all
    case canonical
    case final
    case host(patterns: [HostPattern])
    case originalHost(patterns: [HostPattern])
    case user(patterns: [HostPattern])
    case localUser(patterns: [HostPattern])
    case exec(command: String)
}

enum CanonicalizeMode: String, Sendable, Hashable {
    case no
    case yes
    case always
}

enum SSHDirective: Sendable, Hashable {
    case hostName(String)
    case port(Int)
    case user(String)
    case identityFile(String)
    case identityAgent(String)
    case identitiesOnly(Bool)
    case addKeysToAgent(Bool)
    case useKeychain(Bool)
    case proxyJump(String)
    case canonicalizeHostname(CanonicalizeMode)
    case canonicalDomains([String])
    case canonicalizePermittedCNAMEs(String)
    case canonicalizeFallbackLocal(Bool)
    case canonicalizeMaxDots(Int)
    case unrecognized(key: String, value: String)
}
