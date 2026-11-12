import Foundation

public enum MCPServerTarget: Sendable, Equatable {
    case stdio(command: String)
    case http(url: String, authorization: String)
}

public enum MCPTemplateError: Error, Sendable, Equatable {
    case missingEntry
    case unknownPlaceholder(String)
    case unavailablePlaceholder(String)
    case unknownFilter(String)
    case invalidURL
}

public struct MCPTemplateRenderer: Sendable {
    public let serverName: String
    public let target: MCPServerTarget

    public init(serverName: String, target: MCPServerTarget) {
        self.serverName = serverName
        self.target = target
    }

    public func entry(_ spec: MCPClientPlatformSpec) throws -> JSONValue {
        guard let template = spec.entry else { throw MCPTemplateError.missingEntry }
        return try entry(template: template)
    }

    public func entry(template: JSONValue) throws -> JSONValue {
        switch template {
        case .string(let string):
            return .string(try render(string, entry: nil))
        case .array(let items):
            return .array(try items.map { try entry(template: $0) })
        case .object(let members):
            return .object(try members.map { (key: $0.key, value: try entry(template: $0.value)) })
        case .number, .bool, .null:
            return template
        }
    }

    public func arguments(_ template: [String], entry: JSONValue) throws -> [String] {
        try template.map { try render($0, entry: entry) }
    }

    public func url(_ template: String, entry: JSONValue) throws -> URL {
        guard let url = URL(string: try render(template, entry: entry)) else { throw MCPTemplateError.invalidURL }
        return url
    }

    public func snippet(for location: MCPConfigLocation?, entry: JSONValue) -> String {
        let path = (location?.keyPath ?? []) + [serverName]
        let json = JSONValue.nested(path, leaf: entry).prettyText()
        switch location?.format {
        case .toml:
            guard let block = try? TOMLTableEditor.renderBlock(header: path, value: entry, newline: "\n") else { return json }
            return String(block.dropLast())
        case .yaml:
            return Self.yamlLines(key: path[0], value: JSONValue.nested(Array(path.dropFirst()), leaf: entry), indent: "")
                .joined(separator: "\n")
        case .json, .jsonc, nil:
            return json
        }
    }

    public func commandLine(binary: String, arguments: [String]) -> String {
        ([binary] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    static func shellQuoted(_ word: String) -> String {
        guard !word.isEmpty else { return "''" }
        if word.unicodeScalars.allSatisfy(Self.shellSafe.contains) {
            return word
        }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''", options: .literal) + "'"
    }

    private static let shellSafe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_@%+=:,./-"
    )

    private static let uriUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private enum Rendered {
        case text(String)
        case json(JSONValue)
    }

    private func render(_ template: String, entry: JSONValue?) throws -> String {
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            result += try expand(rest[rest.index(after: open)..<close], entry: entry)
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }

    private func expand(_ expression: Substring, entry: JSONValue?) throws -> String {
        let parts = expression.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        var value = try source(parts[0], entry: entry)
        for filter in parts.dropFirst() {
            value = try apply(filter, to: value)
        }
        switch value {
        case .text(let text): return text
        case .json(let json): return json.compactText
        }
    }

    private func source(_ name: String, entry: JSONValue?) throws -> Rendered {
        switch (name, target) {
        case ("name", _):
            return .text(serverName)
        case let ("command", .stdio(command)):
            return .text(command)
        case let ("url", .http(url, _)):
            return .text(url)
        case let ("authorization", .http(_, authorization)):
            return .text(authorization)
        case ("command", _), ("url", _), ("authorization", _):
            throw MCPTemplateError.unavailablePlaceholder(name)
        case ("entry", _):
            guard let entry else { throw MCPTemplateError.unavailablePlaceholder(name) }
            return .json(entry)
        case ("entryWithName", _):
            guard let entry else { throw MCPTemplateError.unavailablePlaceholder(name) }
            let others = entry.objectMembers?.filter { $0.key != "name" } ?? []
            return .json(.object([(key: "name", value: .string(serverName))] + others))
        default:
            throw MCPTemplateError.unknownPlaceholder(name)
        }
    }

    private func apply(_ filter: String, to value: Rendered) throws -> Rendered {
        switch (filter, value) {
        case let ("json", .json(json)):
            return .text(json.compactText)
        case let ("json", .text(text)):
            return .text(JSONTextStyle.quoted(text))
        case let ("base64", .text(text)):
            return .text(Data(text.utf8).base64EncodedString())
        case let ("uri", .text(text)):
            return .text(text.addingPercentEncoding(withAllowedCharacters: Self.uriUnreserved) ?? text)
        default:
            throw MCPTemplateError.unknownFilter(filter)
        }
    }

    private static func yamlLines(key: String, value: JSONValue, indent: String) -> [String] {
        let label = indent + yamlKey(key) + ":"
        switch value {
        case .object(let members) where !members.isEmpty:
            return [label] + members.flatMap { yamlLines(key: $0.key, value: $0.value, indent: indent + "  ") }
        case .array(let items) where !items.isEmpty:
            return [label] + items.map { indent + "  - " + yamlFlow.render($0, indent: "") }
        default:
            return [label + " " + yamlFlow.render(value, indent: "")]
        }
    }

    // A JSON scalar or flow collection is also valid YAML.
    private static let yamlFlow = JSONTextStyle(indentUnit: "", newline: "", multiline: false, spaced: true)

    private static func yamlKey(_ key: String) -> String {
        guard !key.isEmpty, key.utf8.allSatisfy(TOMLParser.isBareKeyByte) else { return JSONTextStyle.quoted(key) }
        return key
    }
}
