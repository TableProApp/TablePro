//
//  SchemaRegistryClient.swift
//  TablePro
//

import Foundation

// Engine neutral: any driver that declares these connection fields gets the Schema Registry display format.
internal enum SchemaRegistryConnectionField {
    static let url = "schemaRegistryUrl"
    static let username = "schemaRegistryUsername"
    static let password = "schemaRegistryPassword"
}

internal struct SchemaRegistryEndpoint: Hashable, Sendable {
    let baseURL: URL
    let username: String?
    let password: String?

    init?(fields: [String: String]) {
        let text = (fields[SchemaRegistryConnectionField.url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        baseURL = url
        let username = fields[SchemaRegistryConnectionField.username] ?? ""
        self.username = username.isEmpty ? nil : username
        password = fields[SchemaRegistryConnectionField.password]
    }

    // The session's record, so the endpoint changes when the connection does: on the next connect, like every other field.
    @MainActor
    static func connection(for connectionID: UUID) -> DatabaseConnection? {
        DatabaseManager.shared.session(for: connectionID)?.connection
            ?? ConnectionStorage.shared.loadConnection(id: connectionID)
    }

    @MainActor
    static func isConfigured(for connectionID: UUID) -> Bool {
        guard let connection = connection(for: connectionID) else { return false }
        return SchemaRegistryEndpoint(fields: connection.additionalFields) != nil
    }

    @MainActor
    static func resolve(for connectionID: UUID) -> SchemaRegistryEndpoint? {
        guard let connection = connection(for: connectionID) else { return nil }
        let fields = DatabaseDriverFactory.resolvedAdditionalFields(for: connection) ?? connection.additionalFields
        return SchemaRegistryEndpoint(fields: fields)
    }
}

internal enum RegistrySchema: Sendable {
    case avro(AvroSchema)
    case protobuf(ProtobufSchema)
    case json
}

internal struct SchemaRegistryError: Error, Equatable, Sendable {
    let reason: String
}

// https://docs.confluent.io/platform/current/schema-registry/develop/api.html
internal struct SchemaRegistryClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let maxResponseBytes = 4_000_000
    static let maxReferences = 200
    static let timeout: TimeInterval = 15

    let endpoint: SchemaRegistryEndpoint
    let transport: Transport

    init(endpoint: SchemaRegistryEndpoint, transport: @escaping Transport = Self.urlSessionTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    static let urlSessionTransport: Transport = { request in
        guard let url = request.url else { throw URLError(.badURL) }
        let (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirectGuard(origin: url))
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            // Stops a registry that never ends its answer from filling memory.
            if data.count > maxResponseBytes { break }
        }
        return (data, response)
    }

    func schema(id: UInt32) async throws -> RegistrySchema {
        let root: SchemaResponse = try await get(["schemas", "ids", String(id)])
        switch root.schemaType?.uppercased() ?? "AVRO" {
        case "AVRO":
            let references = try await referencedSchemas(root.references ?? [])
            do {
                return .avro(try AvroSchema.parse(root.schema, references: references))
            } catch let error as AvroSchemaError {
                throw SchemaRegistryError(reason: error.reason)
            }
        case "PROTOBUF":
            let references = try await referencedSchemas(root.references ?? [])
            do {
                return .protobuf(try ProtobufSchema.parse(protoFiles: [root.schema] + references))
            } catch let error as ProtobufSchemaError {
                throw SchemaRegistryError(reason: error.reason)
            }
        case "JSON":
            return .json
        case let other:
            throw SchemaRegistryError(reason: String(
                format: String(localized: "The Schema Registry names a schema type TablePro does not read: %@."), other
            ))
        }
    }

    // Each subject version once, after the ones it references, so a type is defined before its users.
    private func referencedSchemas(_ references: [SchemaReference]) async throws -> [String] {
        var texts: [String] = []
        var seen: Set<String> = []
        try await collect(references, into: &texts, seen: &seen)
        return texts
    }

    private func collect(_ references: [SchemaReference], into texts: inout [String], seen: inout Set<String>) async throws {
        for reference in references {
            guard seen.insert("\(reference.subject)@\(reference.version)").inserted else { continue }
            guard seen.count <= Self.maxReferences else {
                throw SchemaRegistryError(reason: String(localized: "The schema imports more files than TablePro reads."))
            }
            let version: SchemaResponse = try await get(["subjects", reference.subject, "versions", String(reference.version)])
            try await collect(version.references ?? [], into: &texts, seen: &seen)
            texts.append(version.schema)
        }
    }

    private func get<Response: Decodable>(_ components: [String]) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request(components))
        } catch {
            throw SchemaRegistryError(reason: String(
                format: String(localized: "TablePro could not reach the Schema Registry: %@"), error.localizedDescription
            ))
        }
        guard data.count <= Self.maxResponseBytes else {
            throw SchemaRegistryError(reason: String(localized: "The Schema Registry's answer is larger than any schema."))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            throw SchemaRegistryError(reason: String(
                format: String(localized: "The Schema Registry answered %lld: %@"), status, message
            ))
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw SchemaRegistryError(reason: String(localized: "The Schema Registry's answer is not a schema."))
        }
    }

    // Each component is encoded alone: a subject such as `demo/common.proto` holds a slash.
    func request(_ components: [String]) -> URLRequest {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let base = endpoint.baseURL.absoluteString.hasSuffix("/")
            ? String(endpoint.baseURL.absoluteString.dropLast())
            : endpoint.baseURL.absoluteString
        let path = components
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
        var request = URLRequest(url: URL(string: "\(base)/\(path)") ?? endpoint.baseURL, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.schemaregistry.v1+json, application/json", forHTTPHeaderField: "Accept")
        if let username = endpoint.username {
            let credentials = Data("\(username):\(endpoint.password ?? "")".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private struct SchemaResponse: Decodable {
        let schema: String
        let schemaType: String?
        let references: [SchemaReference]?
    }

    private struct SchemaReference: Decodable {
        let subject: String
        let version: Int
    }

    private struct ErrorResponse: Decodable {
        let message: String
    }
}
