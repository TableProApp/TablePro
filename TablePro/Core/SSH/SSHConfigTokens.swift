//
//  SSHConfigTokens.swift
//  TablePro
//

import CryptoKit
import Darwin
import Foundation

/// Which `%X` tokens a keyword accepts, per the TOKENS section of ssh_config(5). OpenSSH treats a
/// token outside its keyword's scope as a fatal error rather than passing it through, so the scope
/// is part of the grammar and not a lint.
enum SSHTokenScope: Sendable, Hashable {
    /// `Hostname`, which accepts only `%%` and `%h`.
    case hostname
    /// `ProxyCommand` and `ProxyJump`, which accept `%%`, `%h`, `%n`, `%p` and `%r`.
    case proxy
    /// `CertificateFile`, `ControlPath`, `IdentityAgent`, `IdentityFile`, `KnownHostsCommand`,
    /// `RevokedHostKeys` and `UserKnownHostsFile`: the same tokens as `.matchExec`, and the only
    /// keywords ssh also expands `${VAR}` in.
    case standard
    /// `Match exec`, which takes the full token set but no `${VAR}`: ssh hands the command to the
    /// shell with its dollar expressions intact, so `test x${MODE:-dev} = xdev` is the shell's to
    /// resolve. Expanding it here looked up a variable named `MODE:-dev` and failed the block.
    case matchExec
    /// `Include`. ssh gives it the same tokens as `.standard`, but TablePro parses the config once
    /// and shares the result across every connection, so no host is known while an `Include` is
    /// being resolved. Only the tokens that do not depend on the target are accepted; the rest are
    /// reported rather than resolved against a host that is not the one connecting.
    case includePath

    private static let hostnameTokens: Set<Character> = ["h"]
    private static let proxyTokens: Set<Character> = ["h", "n", "p", "r"]
    private static let standardTokens: Set<Character> = [
        "C", "d", "h", "i", "j", "k", "L", "l", "n", "p", "r", "u",
    ]
    private static let hostIndependentTokens: Set<Character> = ["d", "i", "L", "l", "u"]

    fileprivate func accepts(_ token: Character) -> Bool {
        switch self {
        case .hostname: return Self.hostnameTokens.contains(token)
        case .proxy: return Self.proxyTokens.contains(token)
        case .standard, .matchExec: return Self.standardTokens.contains(token)
        case .includePath: return Self.hostIndependentTokens.contains(token)
        }
    }

    /// ssh_config(5) names the keywords that take `${VAR}`, and it is a shorter list than the one
    /// that takes tokens.
    fileprivate var expandsEnvironmentVariables: Bool {
        switch self {
        case .standard, .includePath: return true
        case .hostname, .proxy, .matchExec: return false
        }
    }
}

enum SSHTokenExpansionError: Error, Hashable, Sendable {
    /// A token the keyword does not accept, which ssh refuses to run at all.
    case unsupportedToken(keyword: String, token: String)
    /// A `%` with no token letter after it.
    case danglingPercent(keyword: String)
    /// A `${VAR}` naming an environment variable that is not set.
    case undefinedEnvironmentVariable(keyword: String, name: String)
    /// A `${` with no closing brace, which ssh refuses to run on.
    case malformedEnvironmentReference(keyword: String)

    var explanation: String {
        switch self {
        case .unsupportedToken(let keyword, let token):
            return String(
                format: String(localized: "`%@` in ~/.ssh/config does not accept the token %@."),
                keyword,
                token
            )
        case .danglingPercent(let keyword):
            return String(
                format: String(localized: "`%@` in ~/.ssh/config ends in a lone %%. Write %%%% for a literal percent sign."),
                keyword
            )
        case .undefinedEnvironmentVariable(let keyword, let name):
            return String(
                format: String(localized: "`%@` in ~/.ssh/config uses ${%@}, which is not set in the environment."),
                keyword,
                name
            )
        case .malformedEnvironmentReference(let keyword):
            return String(
                format: String(localized: "`%@` in ~/.ssh/config has a ${ with no closing brace."),
                keyword
            )
        }
    }
}

/// Snapshot of the values used to expand `%X` tokens, per the TOKENS section of ssh_config(5).
///
///   %%  A literal percent sign.
///   %C  Hash of `%l%h%p%r%j`.
///   %d  Local user's home directory.
///   %h  The remote hostname, after any `HostName` substitution.
///   %i  Local user ID.
///   %j  The `ProxyJump` host, or empty when none is set.
///   %k  The `HostKeyAlias`, or the original hostname when none is set.
///   %L  The local hostname without its domain.
///   %l  The local hostname.
///   %n  The original hostname, as the connection names it.
///   %p  The remote port.
///   %r  The remote username.
///   %u  The local username.
struct SSHTokenContext: Sendable {
    var originalHost: String?
    var hostname: String?
    var port: Int?
    var remoteUser: String?
    var jumpHost: String?
    var hostKeyAlias: String?
    var localUser: String
    var localHostname: String

    init(
        originalHost: String? = nil,
        hostname: String? = nil,
        port: Int? = nil,
        remoteUser: String? = nil,
        jumpHost: String? = nil,
        hostKeyAlias: String? = nil,
        localUser: String = NSUserName(),
        localHostname: String = SSHTokenContext.systemHostname()
    ) {
        self.originalHost = originalHost
        self.hostname = hostname
        self.port = port
        self.remoteUser = remoteUser
        self.jumpHost = jumpHost
        self.hostKeyAlias = hostKeyAlias
        self.localUser = localUser
        self.localHostname = localHostname
    }

    /// One left-to-right pass. Expanding token by token in sequence, the way this used to work, lets
    /// a value substituted early be rescanned by a later token: a home directory holding the two
    /// characters `%h` came back with the hostname spliced into it. A single pass also removes the
    /// need for the sentinel that used to protect `%%`.
    func expand(_ input: String, scope: SSHTokenScope, keyword: String) throws -> String {
        var result = ""
        var index = input.startIndex

        while index < input.endIndex {
            let character = input[index]
            guard character == "%" || character == "$" else {
                result.append(character)
                index = input.index(after: index)
                continue
            }

            if character == "$" {
                guard scope.expandsEnvironmentVariables, Self.opensEnvironmentReference(in: input, at: index) else {
                    result.append(character)
                    index = input.index(after: index)
                    continue
                }
                guard let (name, next) = Self.environmentReference(in: input, at: index) else {
                    throw SSHTokenExpansionError.malformedEnvironmentReference(keyword: keyword)
                }
                guard let value = ProcessInfo.processInfo.environment[name] else {
                    throw SSHTokenExpansionError.undefinedEnvironmentVariable(keyword: keyword, name: name)
                }
                result.append(value)
                index = next
                continue
            }

            let tokenIndex = input.index(after: index)
            guard tokenIndex < input.endIndex else {
                throw SSHTokenExpansionError.danglingPercent(keyword: keyword)
            }

            let token = input[tokenIndex]
            if token == "%" {
                result.append("%")
                index = input.index(after: tokenIndex)
                continue
            }

            guard scope.accepts(token) else {
                throw SSHTokenExpansionError.unsupportedToken(keyword: keyword, token: "%\(token)")
            }

            result.append(value(for: token))
            index = input.index(after: tokenIndex)
        }

        return result
    }

    private func value(for token: Character) -> String {
        switch token {
        case "d": return Self.localHomeDirectory
        case "h": return hostname ?? ""
        case "i": return String(getuid())
        case "j": return jumpHost ?? ""
        case "k": return hostKeyAlias ?? originalHost ?? ""
        case "L": return Self.shortHostname(localHostname)
        case "l": return localHostname
        case "n": return originalHost ?? ""
        case "p": return port.map(String.init) ?? ""
        case "r": return remoteUser ?? ""
        case "u": return localUser
        case "C": return connectionHash()
        default: return ""
        }
    }

    /// `%C` is the SHA-1 of `%l%h%p%r%j`, which is what OpenSSH hashes for `ControlPath`.
    private func connectionHash() -> String {
        let basis = [
            localHostname,
            hostname ?? "",
            port.map(String.init) ?? "",
            remoteUser ?? "",
            jumpHost ?? "",
        ].joined()
        return Insecure.SHA1.hash(data: Data(basis.utf8)).hexEncoded
    }

    /// A `$` only opens a reference when a brace follows it. A bare `$` is an ordinary character.
    private static func opensEnvironmentReference(in input: String, at index: String.Index) -> Bool {
        let braceIndex = input.index(after: index)
        return braceIndex < input.endIndex && input[braceIndex] == "{"
    }

    private static func environmentReference(in input: String, at index: String.Index) -> (String, String.Index)? {
        let braceIndex = input.index(after: index)
        guard braceIndex < input.endIndex, input[braceIndex] == "{" else { return nil }
        let nameStart = input.index(after: braceIndex)
        guard let close = input[nameStart...].firstIndex(of: "}") else { return nil }
        let name = String(input[nameStart..<close])
        guard !name.isEmpty else { return nil }
        return (name, input.index(after: close))
    }

    /// Trailing slash stripped because `URL.path(percentEncoded:)` preserves it for directory URLs,
    /// which produces double slashes on concatenation.
    static var localHomeDirectory: String {
        let raw = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// `%l` is `gethostname(3)`, which is what ssh reads. `ProcessInfo.hostName` returns the
    /// Bonjour name instead, and the two differ on a stock Mac, which changes `%C` silently.
    static func systemHostname() -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard gethostname(&buffer, buffer.count) == 0 else { return "" }
        return String(cString: buffer)
    }

    private static func shortHostname(_ hostname: String) -> String {
        guard let dot = hostname.firstIndex(of: ".") else { return hostname }
        return String(hostname[..<dot])
    }
}
