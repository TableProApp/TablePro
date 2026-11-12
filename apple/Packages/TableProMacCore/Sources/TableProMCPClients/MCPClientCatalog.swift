import Foundation

public enum MCPClientPlatform: String, Sendable, CaseIterable {
    case macos
    case linux
}

public enum MCPClientCatalogError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidField([String])
}

public struct MCPClientCatalog: Decodable, Sendable {
    public let schemaVersion: Int
    public let serverName: String
    public let configs: [String: MCPClientConfigSet]
    public let clients: [MCPClientDefinition]

    static let supportedSchemaVersion = 1

    // Parses the bytes itself: JSONDecoder loses the key order the `json` template filter has to keep.
    public static func decode(_ data: Data) throws -> MCPClientCatalog {
        guard let root = try JSONCParser.parse(Array(data)) else { throw MCPClientCatalogError.invalidField([]) }
        return try MCPClientCatalog(json: root.value)
    }

    public init(from decoder: any Decoder) throws {
        try self.init(json: try JSONValue(from: decoder))
    }

    init(json: JSONValue) throws {
        let reader = FieldReader(value: json, path: [])
        schemaVersion = try reader.int("schemaVersion")
        guard schemaVersion <= Self.supportedSchemaVersion else {
            throw MCPClientCatalogError.unsupportedSchemaVersion(schemaVersion)
        }
        serverName = try reader.string("serverName")
        var configs: [String: MCPClientConfigSet] = [:]
        for (id, value) in try reader.objectMembers("configs") {
            configs[id] = try MCPClientConfigSet(reader: FieldReader(value: value, path: ["configs", id]))
        }
        self.configs = configs
        clients = try reader.array("clients").enumerated().map { position, value in
            try MCPClientDefinition(reader: FieldReader(value: value, path: ["clients", String(position)]))
        }
    }

    public func client(id: String) -> MCPClientDefinition? {
        clients.first { $0.id == id }
    }

    public func client(matchingClientInfoName name: String) -> MCPClientDefinition? {
        clients(matchingClientInfoName: name).first
    }

    // ChatGPT and Codex CLI send one clientInfo name, so a session is one of them only when that one alone is detected.
    public func client(matchingClientInfoName name: String, detected: Set<String>) -> MCPClientDefinition? {
        let candidates = clients(matchingClientInfoName: name)
        guard candidates.count > 1 else { return candidates.first }
        let found = candidates.filter { detected.contains($0.id) }
        return found.count == 1 ? found.first : nil
    }

    // Exact names first, then the longest prefix, so "Visual Studio Code - Insiders" is not taken for VS Code.
    public func clients(matchingClientInfoName name: String) -> [MCPClientDefinition] {
        let lowered = name.lowercased()
        let exact = clients.filter { $0.clientInfoNames.contains { $0.lowercased() == lowered } }
        guard exact.isEmpty else { return exact }
        let lengths = clients.map { client in
            client.clientInfoPrefixes.filter { lowered.hasPrefix($0.lowercased()) }.map(\.count).max() ?? 0
        }
        guard let longest = lengths.max(), longest > 0 else { return [] }
        return zip(clients, lengths).filter { $0.1 == longest }.map(\.0)
    }

    public func location(for client: MCPClientDefinition, platform: MCPClientPlatform) -> MCPConfigLocation? {
        guard let configID = client.configID else { return nil }
        return configs[configID]?.location(for: platform)
    }

    public func httpEntry(for client: MCPClientDefinition) -> JSONValue? {
        MCPClientPlatform.allCases.lazy
            .compactMap { client.spec(for: $0)?.entry }
            .first { Self.containsURLPlaceholder($0) }
    }

    private static func containsURLPlaceholder(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string): return string.contains("{url}")
        case .array(let items): return items.contains(where: containsURLPlaceholder)
        case .object(let members): return members.contains { containsURLPlaceholder($0.value) }
        case .number, .bool, .null: return false
        }
    }
}

public struct MCPClientConfigSet: Sendable, Equatable {
    public let macos: MCPConfigLocation?
    public let linux: MCPConfigLocation?

    public func location(for platform: MCPClientPlatform) -> MCPConfigLocation? {
        switch platform {
        case .macos: return macos
        case .linux: return linux
        }
    }

    init(reader: FieldReader) throws {
        macos = try reader.optional("macos").map(MCPConfigLocation.init(reader:))
        linux = try reader.optional("linux").map(MCPConfigLocation.init(reader:))
    }
}

public enum MCPConfigFormat: String, Sendable, CaseIterable {
    case json
    case jsonc
    case toml
    case yaml
}

public struct MCPConfigLocation: Sendable, Equatable {
    public let path: String
    public let format: MCPConfigFormat
    public let keyPath: [String]
    public let isWritable: Bool
    // An older layout of the same file and scope, such as opencode's V1 `mcp.<name>`; read like keyPath, never written.
    public let alternateKeyPaths: [[String]]
    public let otherScopes: [[String]]

    public init(
        path: String,
        format: MCPConfigFormat,
        keyPath: [String],
        isWritable: Bool = true,
        alternateKeyPaths: [[String]] = [],
        otherScopes: [[String]] = []
    ) {
        self.path = path
        self.format = format
        self.keyPath = keyPath
        self.isWritable = isWritable
        self.alternateKeyPaths = alternateKeyPaths
        self.otherScopes = otherScopes
    }

    init(reader: FieldReader) throws {
        path = try reader.string("path")
        format = try reader.enumeration("format")
        keyPath = try reader.strings("keyPath")
        isWritable = try reader.optional("writable").map { try $0.bool() } ?? true
        alternateKeyPaths = try Self.keyPaths(reader.optional("alternateKeyPaths"))
        otherScopes = try Self.keyPaths(reader.optional("otherScopes"))
    }

    private static func keyPaths(_ reader: FieldReader?) throws -> [[String]] {
        try reader?.elements().map { try $0.stringArray() } ?? []
    }
}

public struct MCPClientDefinition: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let icon: String
    public let configID: String?
    public let clientInfoNames: [String]
    public let clientInfoPrefixes: [String]
    public let macos: MCPClientPlatformSpec?
    public let linux: MCPClientPlatformSpec?

    public func spec(for platform: MCPClientPlatform) -> MCPClientPlatformSpec? {
        switch platform {
        case .macos: return macos
        case .linux: return linux
        }
    }

    init(reader: FieldReader) throws {
        id = try reader.string("id")
        name = try reader.string("name")
        icon = try reader.string("icon")
        configID = try reader.optional("config").map { try $0.string() }
        let clientInfo = reader.optional("clientInfo")
        clientInfoNames = try clientInfo?.optional("names").map { try $0.stringArray() } ?? []
        clientInfoPrefixes = try clientInfo?.optional("prefixes").map { try $0.stringArray() } ?? []
        macos = try reader.optional("macos").map(MCPClientPlatformSpec.init(reader:))
        linux = try reader.optional("linux").map(MCPClientPlatformSpec.init(reader:))
    }
}

public struct MCPClientPlatformSpec: Sendable, Equatable {
    public let detect: [MCPClientDetectRule]
    public let entry: JSONValue?
    public let install: [MCPInstallMethod]
    public let applies: MCPClientApplies?
    public let unsupported: MCPClientUnsupportedReason?

    init(reader: FieldReader) throws {
        detect = try reader.optional("detect")?.elements().map(MCPClientDetectRule.init(reader:)) ?? []
        entry = reader.optional("entry")?.value
        install = try reader.optional("install")?.elements().map(MCPInstallMethod.init(reader:)) ?? []
        applies = try reader.optional("applies").map { try $0.enumeration() }
        unsupported = try reader.optional("unsupported").map { try $0.enumeration() }
    }
}

public enum MCPClientDetectRule: Sendable, Equatable {
    case bundleID(String)
    case binary(name: String, paths: [String])
    case path(String)

    init(reader: FieldReader) throws {
        if let bundleID = reader.optional("bundleId") {
            self = .bundleID(try bundleID.string())
        } else if let binary = reader.optional("binary") {
            self = .binary(name: try binary.string(), paths: try reader.optional("paths")?.stringArray() ?? [])
        } else if let path = reader.optional("path") {
            self = .path(try path.string())
        } else {
            throw MCPClientCatalogError.invalidField(reader.path)
        }
    }
}

public enum MCPInstallMethod: Sendable, Equatable {
    case deeplink(scheme: String, template: String)
    case cli(MCPCLIInstall)
    case file

    init(reader: FieldReader) throws {
        switch try reader.string("kind") {
        case "deeplink":
            self = .deeplink(scheme: try reader.string("scheme"), template: try reader.string("url"))
        case "cli":
            self = .cli(MCPCLIInstall(
                binary: try reader.string("binary"),
                add: try reader.strings("add"),
                remove: try reader.optional("remove")?.stringArray(),
                update: try reader.optional("update").map { try $0.enumeration() } ?? .add
            ))
        case "file":
            self = .file
        default:
            throw MCPClientCatalogError.invalidField(reader.path + ["kind"])
        }
    }
}

public struct MCPCLIInstall: Sendable, Equatable {
    public let binary: String
    public let add: [String]
    public let remove: [String]?
    public let update: MCPCLIUpdate

    public init(binary: String, add: [String], remove: [String]?, update: MCPCLIUpdate) {
        self.binary = binary
        self.add = add
        self.remove = remove
        self.update = update
    }
}

public enum MCPCLIUpdate: String, Sendable {
    case add
    case removeThenAdd
}

public enum MCPClientApplies: String, Sendable {
    case live
    case newSession
    case restartApp
    case reload
}

public enum MCPClientUnsupportedReason: String, Sendable {
    case remoteOnly
    case stdioOnly
}

struct FieldReader {
    let value: JSONValue
    let path: [String]

    func optional(_ key: String) -> FieldReader? {
        guard let child = value[key], child != .null else { return nil }
        return FieldReader(value: child, path: path + [key])
    }

    func field(_ key: String) throws -> FieldReader {
        guard let child = optional(key) else { throw MCPClientCatalogError.invalidField(path + [key]) }
        return child
    }

    func string(_ key: String) throws -> String {
        try field(key).string()
    }

    func strings(_ key: String) throws -> [String] {
        try field(key).stringArray()
    }

    func int(_ key: String) throws -> Int {
        guard case .number(let number) = try field(key).value, let integer = Int(exactly: number) else {
            throw MCPClientCatalogError.invalidField(path + [key])
        }
        return integer
    }

    func array(_ key: String) throws -> [JSONValue] {
        guard let items = try field(key).value.arrayValue else { throw MCPClientCatalogError.invalidField(path + [key]) }
        return items
    }

    func objectMembers(_ key: String) throws -> [(key: String, value: JSONValue)] {
        guard let members = try field(key).value.objectMembers else { throw MCPClientCatalogError.invalidField(path + [key]) }
        return members
    }

    func enumeration<Value: RawRepresentable>(_ key: String) throws -> Value where Value.RawValue == String {
        try field(key).enumeration()
    }

    func string() throws -> String {
        guard let string = value.stringValue else { throw MCPClientCatalogError.invalidField(path) }
        return string
    }

    func bool() throws -> Bool {
        guard case .bool(let bool) = value else { throw MCPClientCatalogError.invalidField(path) }
        return bool
    }

    func stringArray() throws -> [String] {
        try elements().map { try $0.string() }
    }

    func elements() throws -> [FieldReader] {
        guard let items = value.arrayValue else { throw MCPClientCatalogError.invalidField(path) }
        return items.enumerated().map { FieldReader(value: $1, path: path + [String($0)]) }
    }

    func enumeration<Value: RawRepresentable>() throws -> Value where Value.RawValue == String {
        guard let raw = value.stringValue, let result = Value(rawValue: raw) else {
            throw MCPClientCatalogError.invalidField(path)
        }
        return result
    }
}
