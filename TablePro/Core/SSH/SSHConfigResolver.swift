//
//  SSHConfigResolver.swift
//  TablePro
//

import Foundation
import os

struct ResolverEnvironment: Sendable {
    var runShell: @Sendable (String) -> Bool
    var canonicalize: @Sendable (String, SSHCanonicalizationOptions) -> String?
    var currentLocalUser: @Sendable () -> String

    static let live = ResolverEnvironment(
        runShell: SSHMatchExecutor.evaluate,
        canonicalize: { host, options in
            SSHHostnameCanonicalizer.canonicalize(host: host, options: options)
        },
        currentLocalUser: { NSUserName() }
    )
}

enum SSHConfigResolver {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SSHConfigResolver")

    static func resolve(
        _ config: SSHConfiguration,
        document: SSHConfigDocument,
        env: ResolverEnvironment = .live
    ) -> ResolvedSSHTarget {
        resolveTarget(
            originalHost: config.host,
            formPort: config.port,
            formUser: config.username,
            formIdentityFile: config.privateKeyPath,
            formAgentSocket: config.agentSocketPath,
            formJumpHosts: config.jumpHosts,
            document: document,
            env: env
        )
    }

    static func resolve(
        _ jumpHost: SSHJumpHost,
        document: SSHConfigDocument,
        env: ResolverEnvironment = .live
    ) -> ResolvedSSHTarget {
        resolveTarget(
            originalHost: jumpHost.host,
            formPort: jumpHost.port,
            formUser: jumpHost.username,
            formIdentityFile: jumpHost.privateKeyPath,
            formAgentSocket: "",
            formJumpHosts: [],
            document: document,
            env: env
        )
    }

    // MARK: - Core resolution

    private static func resolveTarget(
        originalHost: String,
        formPort: Int?,
        formUser: String,
        formIdentityFile: String,
        formAgentSocket: String,
        formJumpHosts: [SSHJumpHost],
        document: SSHConfigDocument,
        env: ResolverEnvironment
    ) -> ResolvedSSHTarget {
        let localUser = env.currentLocalUser()

        var firstPass = ResolutionState()
        applyMatchingBlocks(
            blocks: document.blocks,
            originalHost: originalHost,
            currentHost: originalHost,
            formUser: formUser,
            localUser: localUser,
            phase: .first,
            canonicalizing: false,
            into: &firstPass,
            env: env
        )

        let resolvedHost = firstPass.hostName ?? originalHost

        let canonicalOptions = SSHCanonicalizationOptions(
            mode: firstPass.canonicalizeHostname ?? .no,
            domains: firstPass.canonicalDomains,
            fallbackLocal: firstPass.canonicalizeFallbackLocal ?? true,
            maxDots: firstPass.canonicalizeMaxDots ?? 1,
            permittedCNAMEs: firstPass.canonicalizePermittedCNAMEs
        )
        let canonicalizedHost: String
        if canonicalOptions.mode != .no, let canonical = env.canonicalize(resolvedHost, canonicalOptions) {
            canonicalizedHost = canonical
        } else {
            canonicalizedHost = resolvedHost
        }

        var secondPass = ResolutionState()
        applyMatchingBlocks(
            blocks: document.blocks,
            originalHost: originalHost,
            currentHost: canonicalizedHost,
            formUser: formUser,
            localUser: localUser,
            phase: .second,
            canonicalizing: canonicalOptions.mode != .no,
            into: &secondPass,
            env: env
        )

        let merged = firstPass.merging(secondPass)

        let effectivePort = formPort ?? merged.port ?? 22
        let effectiveUser = !formUser.isEmpty ? formUser : (merged.user ?? "")
        let effectiveAgentSocket = !formAgentSocket.isEmpty
            ? formAgentSocket
            : (merged.identityAgent ?? "")

        let effectiveIdentityFiles: [String]
        if !formIdentityFile.isEmpty {
            effectiveIdentityFiles = [formIdentityFile]
        } else {
            let tokenContext = SSHTokenContext(
                originalHost: originalHost,
                hostname: canonicalizedHost,
                port: effectivePort,
                remoteUser: effectiveUser.isEmpty ? nil : effectiveUser
            )
            effectiveIdentityFiles = merged.identityFiles.map {
                SSHPathUtilities.expandTilde(tokenContext.expand($0))
            }
        }

        let effectiveProxyJump: [SSHJumpHost]
        if formJumpHosts.isEmpty, let proxyJump = merged.proxyJump {
            effectiveProxyJump = SSHConfigParser.parseProxyJump(proxyJump)
        } else {
            effectiveProxyJump = []
        }

        return ResolvedSSHTarget(
            originalHost: originalHost,
            host: canonicalizedHost.isEmpty ? originalHost : canonicalizedHost,
            port: effectivePort,
            username: effectiveUser,
            identityFiles: effectiveIdentityFiles,
            agentSocketPath: effectiveAgentSocket,
            identitiesOnly: merged.identitiesOnly ?? false,
            useKeychain: merged.useKeychain ?? true,
            addKeysToAgent: merged.addKeysToAgent ?? false,
            proxyJump: effectiveProxyJump
        )
    }

    // MARK: - Block evaluation

    private enum Phase {
        case first
        case second
    }

    private static func applyMatchingBlocks(
        blocks: [SSHConfigBlock],
        originalHost: String,
        currentHost: String,
        formUser: String,
        localUser: String,
        phase: Phase,
        canonicalizing: Bool,
        into state: inout ResolutionState,
        env: ResolverEnvironment
    ) {
        var workingHost: String = phase == .second ? currentHost : (state.hostName ?? currentHost)

        for block in blocks {
            guard blockMatches(
                block,
                originalHost: originalHost,
                currentHost: workingHost,
                formUser: formUser,
                localUser: localUser,
                phase: phase,
                canonicalizing: canonicalizing,
                env: env
            ) else { continue }

            for directive in block.directives {
                state.apply(directive)
            }
            if phase == .first {
                workingHost = state.hostName ?? workingHost
            }
        }
    }

    private static func blockMatches(
        _ block: SSHConfigBlock,
        originalHost: String,
        currentHost: String,
        formUser: String,
        localUser: String,
        phase: Phase,
        canonicalizing: Bool,
        env: ResolverEnvironment
    ) -> Bool {
        switch block.criteria {
        case .global:
            // Global directives apply only in the first pass; the second pass
            // is reserved for Match canonical/final overrides.
            return phase == .first

        case .host(let patterns):
            // Same reasoning: Host blocks apply in the first pass. The second
            // pass only carries Match canonical and Match final overrides.
            guard phase == .first else { return false }
            return SSHHostPatternMatcher.matches(host: currentHost, patterns: patterns)

        case .match(let conditions):
            let isSecondPassMatch = conditions.contains(where: {
                if case .canonical = $0 { return true }
                if case .final = $0 { return true }
                return false
            })
            // Plain Match blocks (no canonical/final) run only on the first pass;
            // Match canonical/final run only on the second pass.
            if isSecondPassMatch && phase != .second { return false }
            if !isSecondPassMatch && phase != .first { return false }

            return matchConditionsHold(
                conditions,
                originalHost: originalHost,
                currentHost: currentHost,
                formUser: formUser,
                localUser: localUser,
                phase: phase,
                canonicalizing: canonicalizing,
                env: env
            )
        }
    }

    private static func matchConditionsHold(
        _ conditions: [MatchCondition],
        originalHost: String,
        currentHost: String,
        formUser: String,
        localUser: String,
        phase: Phase,
        canonicalizing: Bool,
        env: ResolverEnvironment
    ) -> Bool {
        for condition in conditions {
            switch condition {
            case .all:
                continue

            case .canonical:
                if !canonicalizing { return false }

            case .final:
                continue

            case .host(let patterns):
                if !SSHHostPatternMatcher.matches(host: currentHost, patterns: patterns) {
                    return false
                }

            case .originalHost(let patterns):
                if !SSHHostPatternMatcher.matches(host: originalHost, patterns: patterns) {
                    return false
                }

            case .user(let patterns):
                if !SSHHostPatternMatcher.matches(host: formUser, patterns: patterns) {
                    return false
                }

            case .localUser(let patterns):
                if !SSHHostPatternMatcher.matches(host: localUser, patterns: patterns) {
                    return false
                }

            case .exec(let command):
                let context = SSHTokenContext(
                    originalHost: originalHost,
                    hostname: currentHost,
                    port: nil,
                    remoteUser: formUser.isEmpty ? nil : formUser
                )
                let expanded = context.expand(command)
                if !env.runShell(expanded) {
                    return false
                }
            }
        }
        return true
    }
}

// MARK: - Resolution state

private struct ResolutionState {
    var hostName: String?
    var port: Int?
    var user: String?
    var identityFiles: [String] = []
    var identityAgent: String?
    var proxyJump: String?
    var identitiesOnly: Bool?
    var addKeysToAgent: Bool?
    var useKeychain: Bool?
    var canonicalizeHostname: CanonicalizeMode?
    var canonicalDomains: [String] = []
    var canonicalizePermittedCNAMEs: String?
    var canonicalizeFallbackLocal: Bool?
    var canonicalizeMaxDots: Int?

    mutating func apply(_ directive: SSHDirective) {
        switch directive {
        case .hostName(let value):
            if hostName == nil { hostName = value }
        case .port(let value):
            if port == nil { port = value }
        case .user(let value):
            if user == nil { user = value }
        case .identityFile(let value):
            identityFiles.append(value)
        case .identityAgent(let value):
            if identityAgent == nil { identityAgent = value }
        case .proxyJump(let value):
            if proxyJump == nil { proxyJump = value }
        case .identitiesOnly(let value):
            if identitiesOnly == nil { identitiesOnly = value }
        case .addKeysToAgent(let value):
            if addKeysToAgent == nil { addKeysToAgent = value }
        case .useKeychain(let value):
            if useKeychain == nil { useKeychain = value }
        case .canonicalizeHostname(let value):
            if canonicalizeHostname == nil { canonicalizeHostname = value }
        case .canonicalDomains(let domains):
            if canonicalDomains.isEmpty { canonicalDomains = domains }
        case .canonicalizePermittedCNAMEs(let value):
            if canonicalizePermittedCNAMEs == nil { canonicalizePermittedCNAMEs = value }
        case .canonicalizeFallbackLocal(let value):
            if canonicalizeFallbackLocal == nil { canonicalizeFallbackLocal = value }
        case .canonicalizeMaxDots(let value):
            if canonicalizeMaxDots == nil { canonicalizeMaxDots = value }
        case .unrecognized:
            break
        }
    }

    /// Merge another state on top of this one. Non-nil scalars in `other`
    /// overwrite this state's values; lists in `other` overwrite if non-empty.
    /// Used to apply `Match final` overrides on top of first-pass values.
    func merging(_ other: ResolutionState) -> ResolutionState {
        var result = self
        if let value = other.hostName { result.hostName = value }
        if let value = other.port { result.port = value }
        if let value = other.user { result.user = value }
        if !other.identityFiles.isEmpty { result.identityFiles = other.identityFiles }
        if let value = other.identityAgent { result.identityAgent = value }
        if let value = other.proxyJump { result.proxyJump = value }
        if let value = other.identitiesOnly { result.identitiesOnly = value }
        if let value = other.addKeysToAgent { result.addKeysToAgent = value }
        if let value = other.useKeychain { result.useKeychain = value }
        if let value = other.canonicalizeHostname { result.canonicalizeHostname = value }
        if !other.canonicalDomains.isEmpty { result.canonicalDomains = other.canonicalDomains }
        if let value = other.canonicalizePermittedCNAMEs { result.canonicalizePermittedCNAMEs = value }
        if let value = other.canonicalizeFallbackLocal { result.canonicalizeFallbackLocal = value }
        if let value = other.canonicalizeMaxDots { result.canonicalizeMaxDots = value }
        return result
    }
}
