import Foundation

public enum MCPClientStaleReason: Sendable, Equatable {
    case commandMissing
    case otherCommand
    case otherURL
    case otherToken
    // The keyPath entry is current, but another scope's entry points elsewhere and wins there; `scope` is the key `*` matched.
    case shadowed(scope: String)
}

public enum MCPClientConfigStatus: Sendable, Equatable {
    case notConfigured
    case current
    case stale(MCPClientStaleReason)
    case otherScope
    case disabled
    // A stdio target was expected, but the entry reaches TablePro over HTTP with a token the user chose.
    case usesToken
    case unreadable
    case unknown
}

public enum MCPClientStatusEvaluator {
    public static func status(
        configText: String?,
        location: MCPConfigLocation?,
        serverName: String,
        expected: MCPServerTarget,
        fileExists: (String) -> Bool
    ) -> MCPClientConfigStatus {
        guard let location, location.format != .yaml else { return .unknown }
        guard let configText else { return .notConfigured }
        let entry: JSONValue?
        do {
            entry = try primaryEntry(serverName, location: location, text: configText)
        } catch {
            return .unreadable
        }
        let scoped = location.otherScopes.flatMap { scope in
            scopedEntries(serverName, in: scope, text: configText, format: location.format, fileExists: fileExists)
        }
        guard let entry else {
            return scoped.isEmpty ? .notConfigured : .otherScope
        }
        let status = evaluate(entry, expected: expected, fileExists: fileExists)
        guard status == .current else { return status }
        let shadowing = scoped.first { scopedEntry in
            if case .stale = evaluate(scopedEntry.entry, expected: expected, fileExists: fileExists) { return true }
            return false
        }
        return shadowing.map { .stale(.shadowed(scope: $0.scope)) } ?? .current
    }

    private static func evaluate(_ entry: JSONValue, expected: MCPServerTarget, fileExists: (String) -> Bool) -> MCPClientConfigStatus {
        // Turned off is the user's choice whatever the entry points at, so it is never offered an Update.
        guard !isTurnedOff(entry) else { return .disabled }
        switch expected {
        case .stdio(let command):
            guard let configured = commandValue(entry) else {
                return urlValue(entry) == nil ? .stale(.otherCommand) : .usesToken
            }
            guard configured == command else {
                return fileExists(configured) ? .stale(.otherCommand) : .stale(.commandMissing)
            }
        case let .http(url, authorization):
            guard let configured = urlValue(entry) else {
                return commandValue(entry) == nil ? .stale(.otherURL) : .stale(.otherCommand)
            }
            guard sameEndpoint(configured, url) else { return .stale(.otherURL) }
            guard let header = authorizationValue(entry),
                  header.trimmingCharacters(in: .whitespaces) == authorization.trimmingCharacters(in: .whitespaces) else {
                return .stale(.otherToken)
            }
        }
        return .current
    }

    private static func isTurnedOff(_ entry: JSONValue) -> Bool {
        entry["disabled"] == .bool(true) || entry["enabled"] == .bool(false)
    }

    private static func primaryEntry(_ name: String, location: MCPConfigLocation, text: String) throws -> JSONValue? {
        for keyPath in [location.keyPath] + location.alternateKeyPaths {
            if let entry = try member(name, at: keyPath, in: text, format: location.format) {
                return entry
            }
        }
        return nil
    }

    private static func member(_ name: String, at keyPath: [String], in text: String, format: MCPConfigFormat) throws -> JSONValue? {
        switch format {
        case .json, .jsonc: return try JSONCMemberEditor.member(name, at: keyPath, in: text)
        case .toml: return try TOMLTableEditor.member(name, at: keyPath, in: text)
        case .yaml: return nil
        }
    }

    // Another scope is someone else's layout, so an odd shape there is skipped rather than making the file unreadable.
    private static func scopedEntries(
        _ name: String,
        in scope: [String],
        text: String,
        format: MCPConfigFormat,
        fileExists: (String) -> Bool
    ) -> [(scope: String, entry: JSONValue)] {
        let label = scope.joined(separator: ".")
        guard format == .json || format == .jsonc else {
            guard !scope.contains("*"), let entry = try? member(name, at: scope, in: text, format: format) else { return [] }
            return [(scope: label, entry: entry)]
        }
        guard let root = try? JSONCParser.parse(Array(text.utf8))?.value else { return [] }
        var candidates: [(scope: String, value: JSONValue)] = [(scope: label, value: root)]
        for key in scope {
            candidates = candidates.flatMap { candidate -> [(scope: String, value: JSONValue)] in
                if key == "*" {
                    return (candidate.value.objectMembers ?? [])
                        .filter { !isGoneFolder($0.key, fileExists: fileExists) }
                        .map { (scope: $0.key, value: $0.value) }
                }
                return candidate.value[key].map { [(scope: candidate.scope, value: $0)] } ?? []
            }
        }
        return candidates.compactMap { candidate in
            candidate.value[name].map { (scope: candidate.scope, entry: $0) }
        }
    }

    // Claude Code keeps a project for every folder it ever opened, so one deleted since says nothing about today.
    private static func isGoneFolder(_ key: String, fileExists: (String) -> Bool) -> Bool {
        key.hasPrefix("/") && !fileExists(key)
    }

    private static func commandValue(_ entry: JSONValue) -> String? {
        for key in MCPEntryUpdate.commandKeys {
            switch entry[key] {
            case .string(let command)?: return command
            case .array(let parts)?: return parts.first?.stringValue
            default: continue
            }
        }
        return nil
    }

    private static func urlValue(_ entry: JSONValue) -> String? {
        MCPEntryUpdate.urlKeys.lazy.compactMap { entry[$0]?.stringValue }.first
    }

    private static func authorizationValue(_ entry: JSONValue) -> String? {
        for key in ["headers", "http_headers"] {
            if let header = entry[key]?.objectMembers?.first(where: { $0.key.lowercased() == "authorization" }) {
                return header.value.stringValue
            }
        }
        return nil
    }

    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    private static func sameEndpoint(_ configured: String, _ expected: String) -> Bool {
        guard let left = URLComponents(string: configured), let right = URLComponents(string: expected),
              let leftScheme = left.scheme?.lowercased(), let rightScheme = right.scheme?.lowercased() else {
            return configured == expected
        }
        let leftHost = left.host?.lowercased() ?? ""
        let rightHost = right.host?.lowercased() ?? ""
        let sameHost = leftHost == rightHost || (loopbackHosts.contains(leftHost) && loopbackHosts.contains(rightHost))
        return leftScheme == rightScheme && sameHost
            && port(left, scheme: leftScheme) == port(right, scheme: rightScheme)
            && trimmedPath(left.path) == trimmedPath(right.path)
    }

    private static func port(_ components: URLComponents, scheme: String) -> Int? {
        components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }

    private static func trimmedPath(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
