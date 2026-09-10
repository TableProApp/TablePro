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
    /// `%l` and `%L`, and through them `%C`. Injected because the real value is whatever this Mac
    /// is called, which no test can predict.
    var localHostname: @Sendable () -> String

    init(
        runShell: @escaping @Sendable (String) -> Bool,
        canonicalize: @escaping @Sendable (String, SSHCanonicalizationOptions) -> String?,
        currentLocalUser: @escaping @Sendable () -> String,
        localHostname: @escaping @Sendable () -> String = { SSHTokenContext.systemHostname() }
    ) {
        self.runShell = runShell
        self.canonicalize = canonicalize
        self.currentLocalUser = currentLocalUser
        self.localHostname = localHostname
    }

    static let live = ResolverEnvironment(
        runShell: SSHMatchExecutor.evaluate,
        canonicalize: { host, options in
            SSHHostnameCanonicalizer.canonicalize(host: host, options: options)
        },
        currentLocalUser: { NSUserName() },
        localHostname: { SSHTokenContext.systemHostname() }
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
        var failure: SSHTokenExpansionError?

        var firstPass = ResolutionState()
        applyMatchingBlocks(
            blocks: document.blocks,
            pass: PassInputs(
                originalHost: originalHost,
                currentHost: originalHost,
                formUser: formUser,
                formPort: formPort,
                localUser: localUser,
                phase: .first,
                canonicalizing: false
            ),
            into: &firstPass,
            failure: &failure,
            env: env
        )

        // `%h` inside `HostName` is the host as it stood before this `HostName` applied, which is
        // the original target: ssh expands it against `host_arg`, and a second `HostName` never
        // takes effect because the keyword is first-wins. So `Hostname %h` is a no-op that names
        // the host the connection already asked for, which is exactly what `Host *.*` relies on.
        let substitutedHost = expandHostName(
            firstPass.hostName,
            against: originalHost,
            failure: &failure
        ) ?? originalHost

        let canonicalOptions = SSHCanonicalizationOptions(
            mode: firstPass.canonicalizeHostname ?? .no,
            domains: firstPass.canonicalDomains,
            fallbackLocal: firstPass.canonicalizeFallbackLocal ?? true,
            maxDots: firstPass.canonicalizeMaxDots ?? 1,
            permittedCNAMEs: firstPass.canonicalizePermittedCNAMEs
        )
        let canonicalizedHost: String
        if canonicalOptions.mode != .no, let canonical = env.canonicalize(substitutedHost, canonicalOptions) {
            canonicalizedHost = canonical
        } else {
            canonicalizedHost = substitutedHost
        }

        var secondPass = ResolutionState()
        applyMatchingBlocks(
            blocks: document.blocks,
            pass: PassInputs(
                originalHost: originalHost,
                currentHost: canonicalizedHost,
                formUser: formUser,
                formPort: formPort,
                localUser: localUser,
                phase: .second,
                canonicalizing: canonicalOptions.mode != .no
            ),
            into: &secondPass,
            failure: &failure,
            env: env
        )

        let merged = firstPass.merging(secondPass)

        let effectivePort = formPort ?? merged.port ?? 22
        let effectiveUser = !formUser.isEmpty ? formUser : (merged.user ?? "")
        let effectiveHost = canonicalizedHost.isEmpty ? originalHost : canonicalizedHost

        let proxyContext = SSHTokenContext(
            originalHost: originalHost,
            hostname: effectiveHost,
            port: effectivePort,
            remoteUser: effectiveUser.isEmpty ? nil : effectiveUser,
            localUser: localUser,
            localHostname: env.localHostname()
        )

        // Split the hops before expanding them, the way ssh does. Expanding first lets a value
        // carrying a comma, `%r` with a username like `bob,evil.example.net`, turn one configured
        // hop into two and route the session through a host the config never named.
        let effectiveProxyJump: [SSHJumpHost]
        if formJumpHosts.isEmpty, let proxyJump = merged.proxyJump {
            effectiveProxyJump = SSHConfigParser.splitProxyJumpHops(proxyJump).compactMap { hop in
                expand(hop, scope: .proxy, keyword: "ProxyJump", with: proxyContext, failure: &failure)
                    .flatMap(SSHConfigParser.parseProxyJumpHop)
            }
        } else {
            effectiveProxyJump = []
        }

        // `%j` is the jump host actually in effect, and with several hops ssh names the LAST one,
        // the hop nearest the target. Jump hosts typed into the form override the config's
        // `ProxyJump` the way `ssh -J` does, so they are what `%j` and therefore `%C` are built
        // from, or an `IdentityFile` keyed on `%C` names a key for a hop nobody uses.
        let jumpHostForTokens = (formJumpHosts.isEmpty ? effectiveProxyJump : formJumpHosts).last?.host
        var fileContext = proxyContext
        fileContext.jumpHost = jumpHostForTokens
        fileContext.hostKeyAlias = merged.hostKeyAlias

        let effectiveIdentityFiles: [String]
        if !formIdentityFile.isEmpty {
            effectiveIdentityFiles = [formIdentityFile]
        } else {
            effectiveIdentityFiles = merged.identityFiles.compactMap { path in
                expand(path, scope: .standard, keyword: "IdentityFile", with: fileContext, failure: &failure)
                    .map(SSHPathUtilities.expandTilde)
            }
        }

        let effectiveAgentSocket: String
        let agentSocketOrigin: AgentSocketOrigin
        if !formAgentSocket.isEmpty {
            effectiveAgentSocket = formAgentSocket
            agentSocketOrigin = .agentSocketSetting
        } else if let identityAgent = merged.identityAgent, !identityAgent.isEmpty {
            let expanded = expand(
                identityAgent,
                scope: .standard,
                keyword: "IdentityAgent",
                with: fileContext,
                failure: &failure
            )
            effectiveAgentSocket = expanded.map(SSHPathUtilities.expandTilde) ?? ""
            agentSocketOrigin = .identityAgentDirective
        } else {
            effectiveAgentSocket = ""
            agentSocketOrigin = .environment
        }

        return ResolvedSSHTarget(
            originalHost: originalHost,
            host: effectiveHost,
            port: effectivePort,
            username: effectiveUser,
            identityFiles: effectiveIdentityFiles,
            agentSocketPath: effectiveAgentSocket,
            agentSocketOrigin: agentSocketOrigin,
            identitiesOnly: merged.identitiesOnly ?? false,
            useKeychain: merged.useKeychain ?? true,
            addKeysToAgent: merged.addKeysToAgent ?? false,
            proxyJump: effectiveProxyJump,
            expansionFailure: failure
        )
    }

    // MARK: - Token expansion

    /// Expands one directive value, keeping the first failure so the connect path can report which
    /// keyword and token stopped it. ssh refuses to start at all on one of these, and passing the
    /// raw value through instead is what sent the two characters `%h` to `getaddrinfo`.
    private static func expand(
        _ value: String,
        scope: SSHTokenScope,
        keyword: String,
        with context: SSHTokenContext,
        failure: inout SSHTokenExpansionError?
    ) -> String? {
        do {
            return try context.expand(value, scope: scope, keyword: keyword)
        } catch let error as SSHTokenExpansionError {
            logger.warning("\(error.explanation, privacy: .public)")
            if failure == nil { failure = error }
            return nil
        } catch {
            return nil
        }
    }

    private static func expandHostName(
        _ hostName: String?,
        against originalHost: String,
        failure: inout SSHTokenExpansionError?
    ) -> String? {
        guard let hostName, !hostName.isEmpty else { return nil }
        let context = SSHTokenContext(originalHost: originalHost, hostname: originalHost)
        return expand(hostName, scope: .hostname, keyword: "HostName", with: context, failure: &failure)
    }

    // MARK: - Block evaluation

    private enum Phase {
        case first
        case second
    }

    /// Everything a block is matched against. The two host values are deliberately separate:
    /// `Host` patterns are compared to the host the connection named, `Match host` to the one a
    /// `HostName` substituted.
    private struct MatchInputs {
        let originalHost: String
        let hostForHostPatterns: String
        let hostForMatchHost: String
        let formUser: String
        let localUser: String
        let resolvedUser: String?
        let formPort: Int?
        let resolvedPort: Int?
        let phase: Phase
        let canonicalizing: Bool

        /// What the connection would use if resolution stopped here. `Match exec` reads the port
        /// and user the way every other keyword does, so an implicit 22 has to be a 22: leaving
        /// `%p` empty made `test x%p = x22` fail and silently drop the block's directives.
        var effectivePort: Int { formPort ?? resolvedPort ?? 22 }
        var effectiveUser: String? {
            let user = !formUser.isEmpty ? formUser : (resolvedUser ?? "")
            return user.isEmpty ? nil : user
        }
    }

    /// The values a pass is evaluated against that do not change while it runs.
    private struct PassInputs {
        let originalHost: String
        let currentHost: String
        let formUser: String
        let formPort: Int?
        let localUser: String
        let phase: Phase
        let canonicalizing: Bool
    }

    private static func applyMatchingBlocks(
        blocks: [SSHConfigBlock],
        pass: PassInputs,
        into state: inout ResolutionState,
        failure: inout SSHTokenExpansionError?,
        env: ResolverEnvironment
    ) {
        for block in blocks {
            // `Match host` sees the substituted hostname, so the running `HostName` has to be
            // expanded before it is compared. `Host` patterns do not: ssh matches those against the
            // host the connection named, so feeding them the substitution made wildcard blocks for
            // a private domain apply to an alias that never mentioned it.
            let matchHost = expandHostName(
                state.hostName,
                against: pass.originalHost,
                failure: &failure
            ) ?? pass.currentHost
            let inputs = MatchInputs(
                originalHost: pass.originalHost,
                hostForHostPatterns: pass.currentHost,
                hostForMatchHost: matchHost,
                formUser: pass.formUser,
                localUser: pass.localUser,
                resolvedUser: state.user,
                formPort: pass.formPort,
                resolvedPort: state.port,
                phase: pass.phase,
                canonicalizing: pass.canonicalizing
            )

            guard blockMatches(block, inputs: inputs, failure: &failure, env: env) else { continue }

            for directive in block.directives {
                warnIfRoutingDirectiveIgnored(directive)
                state.apply(directive)
            }
        }
    }

    /// Reports a directive that decides how the connection reaches the server and that TablePro
    /// cannot honour. Dropping one without a word leaves a connection that works in Terminal and
    /// fails here, with nothing pointing at `~/.ssh/config`.
    private static func warnIfRoutingDirectiveIgnored(_ directive: SSHDirective) {
        guard case .unrecognized(let key, _) = directive,
              SSHUnsupportedDirective.changesRouting(key: key) else { return }

        logger.warning(
            "Ignoring \(key) from ssh_config: TablePro connects to the host directly, so this connection may not reach the same server ssh would"
        )
    }

    private static func blockMatches(
        _ block: SSHConfigBlock,
        inputs: MatchInputs,
        failure: inout SSHTokenExpansionError?,
        env: ResolverEnvironment
    ) -> Bool {
        switch block.criteria {
        case .global:
            // Global directives apply only in the first pass; the second pass
            // is reserved for Match canonical/final overrides.
            return inputs.phase == .first

        case .host(let patterns):
            // Same reasoning: Host blocks apply in the first pass. The second
            // pass only carries Match canonical and Match final overrides.
            guard inputs.phase == .first else { return false }
            return SSHHostPatternMatcher.matches(host: inputs.hostForHostPatterns, patterns: patterns)

        case .match(let conditions):
            // Only an un-negated `canonical` or `final` defers a block to the second pass. ssh
            // evaluates `Match !final` on the first one, where `final` is false, so treating the
            // negation as a second-pass criterion meant it could never apply at all.
            let isSecondPassMatch = conditions.contains { condition in
                guard !condition.negated else { return false }
                if case .canonical = condition.test { return true }
                if case .final = condition.test { return true }
                return false
            }
            // Plain Match blocks (no canonical/final) run only on the first pass;
            // Match canonical/final run only on the second pass.
            if isSecondPassMatch && inputs.phase != .second { return false }
            if !isSecondPassMatch && inputs.phase != .first { return false }

            return matchConditionsHold(conditions, inputs: inputs, failure: &failure, env: env)
        }
    }

    private static func matchConditionsHold(
        _ conditions: [MatchCondition],
        inputs: MatchInputs,
        failure: inout SSHTokenExpansionError?,
        env: ResolverEnvironment
    ) -> Bool {
        for condition in conditions {
            // A criterion that could not be evaluated fails the block whichever way it was
            // written. Reporting it as "did not hold" instead let a negated one be satisfied by
            // its own failure, so a `Match !exec` block applied precisely when its probe broke.
            guard let holds = conditionHolds(condition.test, inputs: inputs, failure: &failure, env: env) else {
                return false
            }
            if holds == condition.negated { return false }
        }
        return true
    }

    /// Returns nil when the criterion could not be evaluated at all, which is not the same as it
    /// not holding.
    private static func conditionHolds(
        _ test: MatchTest,
        inputs: MatchInputs,
        failure: inout SSHTokenExpansionError?,
        env: ResolverEnvironment
    ) -> Bool? {
        switch test {
        case .all:
            return true

        case .canonical:
            return inputs.canonicalizing

        case .final:
            // True only on the final pass, which is what makes `Match !final` a first-pass
            // criterion. Answering true everywhere left the negation permanently unsatisfiable.
            return inputs.phase == .second

        case .host(let patterns):
            // `Match host` folds case on both sides, which `Host` does not.
            return SSHHostPatternMatcher.matches(
                host: inputs.hostForMatchHost,
                patterns: patterns,
                caseSensitive: false
            )

        case .originalHost(let patterns):
            return SSHHostPatternMatcher.matches(host: inputs.originalHost, patterns: patterns)

        case .user(let patterns):
            let user = !inputs.formUser.isEmpty ? inputs.formUser : (inputs.resolvedUser ?? "")
            return SSHHostPatternMatcher.matches(host: user, patterns: patterns)

        case .localUser(let patterns):
            return SSHHostPatternMatcher.matches(host: inputs.localUser, patterns: patterns)

        case .exec(let command):
            // `Match exec` takes the full token set, and the port and remote user are part of it.
            // Passing neither left `%p` and `%r` in the command, so a probe like `nc -z %h %p` ran
            // against a literal `%p`, failed, and silently dropped whatever the block set.
            let context = SSHTokenContext(
                originalHost: inputs.originalHost,
                hostname: inputs.hostForMatchHost,
                port: inputs.effectivePort,
                remoteUser: inputs.effectiveUser,
                localUser: inputs.localUser,
                localHostname: env.localHostname()
            )
            guard let expanded = expand(
                command,
                scope: .matchExec,
                keyword: "Match exec",
                with: context,
                failure: &failure
            ) else { return nil }
            return env.runShell(expanded)
        }
    }
}

// MARK: - Resolution state

private struct ResolutionState {
    var hostName: String?
    var port: Int?
    var user: String?
    var hostKeyAlias: String?
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
            // An empty argument is not a value. Taking it as one resolved the host to "".
            if hostName == nil, !value.isEmpty { hostName = value }
        case .port(let value):
            if port == nil { port = value }
        case .user(let value):
            if user == nil, !value.isEmpty { user = value }
        case .hostKeyAlias(let value):
            if hostKeyAlias == nil, !value.isEmpty { hostKeyAlias = value }
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

    /// Fold the second pass into the first. ssh keeps the first value it obtained for a keyword,
    /// and that holds across both passes: a `Match final` block supplies a default for something no
    /// earlier block set, it does not override one. Letting the second pass win made a `Match final`
    /// fallback discard every per-host `User` and `Port`. `IdentityFile` accumulates across the
    /// whole parse rather than being replaced, so a shared key added late joins the per-host ones.
    func merging(_ other: ResolutionState) -> ResolutionState {
        var result = self
        // `hostName` is deliberately absent: the connect host is settled from the first pass before
        // the second one runs, and ssh ignores a `HostName` in a final pass for the same reason.
        if result.port == nil { result.port = other.port }
        if result.user == nil { result.user = other.user }
        if result.hostKeyAlias == nil { result.hostKeyAlias = other.hostKeyAlias }
        result.identityFiles.append(contentsOf: other.identityFiles)
        if result.identityAgent == nil { result.identityAgent = other.identityAgent }
        if result.proxyJump == nil { result.proxyJump = other.proxyJump }
        if result.identitiesOnly == nil { result.identitiesOnly = other.identitiesOnly }
        if result.addKeysToAgent == nil { result.addKeysToAgent = other.addKeysToAgent }
        if result.useKeychain == nil { result.useKeychain = other.useKeychain }
        if result.canonicalizeHostname == nil { result.canonicalizeHostname = other.canonicalizeHostname }
        if result.canonicalDomains.isEmpty { result.canonicalDomains = other.canonicalDomains }
        if result.canonicalizePermittedCNAMEs == nil {
            result.canonicalizePermittedCNAMEs = other.canonicalizePermittedCNAMEs
        }
        if result.canonicalizeFallbackLocal == nil {
            result.canonicalizeFallbackLocal = other.canonicalizeFallbackLocal
        }
        if result.canonicalizeMaxDots == nil { result.canonicalizeMaxDots = other.canonicalizeMaxDots }
        return result
    }
}
