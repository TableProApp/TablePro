import Foundation
import TableProGoogleCloud

public struct SpannerConnectionSettings: Sendable, Equatable {
    public enum FieldKey {
        public static let projectId = "spProjectId"
        public static let instanceId = "spInstanceId"
        public static let databaseId = "spDatabaseId"
        public static let endpoint = "spEndpoint"
        public static let authMethod = "spAuthMethod"
    }

    public static let productionEndpoint = SpannerStaticURL.make("https://spanner.googleapis.com")

    public let projectId: String
    public let instanceId: String
    public let databaseId: String
    public let endpoint: URL
    public let authMethod: SpannerAuthMethod

    public var databasePath: String {
        "projects/\(projectId)/instances/\(instanceId)/databases/\(databaseId)"
    }

    init(projectId: String, instanceId: String, databaseId: String, endpoint: URL, authMethod: SpannerAuthMethod) {
        self.projectId = projectId
        self.instanceId = instanceId
        self.databaseId = databaseId
        self.endpoint = endpoint
        self.authMethod = authMethod
    }

    public static func parse(fields: [String: String]) throws -> SpannerConnectionSettings {
        let authMethod = try parseAuthMethod(fields[FieldKey.authMethod])
        let projectId = try identifier(fields, key: FieldKey.projectId)
        let instanceId = try identifier(fields, key: FieldKey.instanceId)
        let databaseId = try identifier(fields, key: FieldKey.databaseId)
        let endpoint = try parseEndpoint(fields[FieldKey.endpoint], authMethod: authMethod)
        return SpannerConnectionSettings(
            projectId: projectId,
            instanceId: instanceId,
            databaseId: databaseId,
            endpoint: endpoint,
            authMethod: authMethod
        )
    }
}

internal enum SpannerStaticURL {
    static func make(_ literal: StaticString) -> URL {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("A static Spanner endpoint literal did not form a URL")
        }
        return url
    }
}

private extension SpannerConnectionSettings {
    static let identifierLeadingCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )
    static let identifierCharacters = identifierLeadingCharacters.union(CharacterSet(charactersIn: "._:-"))

    static func trimmed(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseAuthMethod(_ value: String?) throws -> SpannerAuthMethod {
        let text = trimmed(value)
        guard !text.isEmpty else { return .serviceAccount }
        guard let method = SpannerAuthMethod(rawValue: text) else {
            throw SpannerConfigurationError.unknownAuthMethod(text)
        }
        return method
    }

    static func identifier(_ fields: [String: String], key: String) throws -> String {
        let text = trimmed(fields[key])
        guard !text.isEmpty else { throw SpannerConfigurationError.missingField(key) }
        guard isValidIdentifier(text) else { throw SpannerConfigurationError.invalidIdentifier(key) }
        return text
    }

    static func isValidIdentifier(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        guard let first = scalars.first, identifierLeadingCharacters.contains(first) else { return false }
        guard scalars.allSatisfy({ identifierCharacters.contains($0) }) else { return false }
        return !text.contains("..")
    }

    static func parseEndpoint(_ value: String?, authMethod: SpannerAuthMethod) throws -> URL {
        let text = trimmed(value)
        if text.isEmpty {
            guard authMethod != .emulator else {
                throw SpannerConfigurationError.missingField(FieldKey.endpoint)
            }
            return productionEndpoint
        }
        let url = try endpointURL(text, defaultScheme: authMethod == .emulator ? "http" : "https")
        guard authMethod == .emulator else {
            guard GoogleEndpointPolicy.isTrustedGoogleAPI(url) else {
                throw SpannerConfigurationError.untrustedEndpoint
            }
            return url
        }
        guard GoogleEndpointPolicy.isLoopback(url) else {
            throw SpannerConfigurationError.emulatorRequiresLoopback
        }
        return url
    }

    static func endpointURL(_ text: String, defaultScheme: String) throws -> URL {
        let spelled = text.contains("://") ? text : "\(defaultScheme)://\(text)"
        guard let components = URLComponents(string: spelled),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let url = components.url
        else {
            throw SpannerConfigurationError.invalidEndpoint
        }
        return url
    }
}
