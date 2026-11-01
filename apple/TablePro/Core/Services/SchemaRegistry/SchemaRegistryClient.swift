//
//  SchemaRegistryClient.swift
//  TablePro
//

import Foundation

// The connection fields a driver declares to name its Schema Registry. Engine neutral: any plugin that declares
// them gets the Schema Registry display format.
internal enum SchemaRegistryConnectionField {
    static let url = "schemaRegistryUrl"
    static let username = "schemaRegistryUsername"
    static let password = "schemaRegistryPassword"
}

internal struct SchemaRegistryEndpoint: Equatable, Sendable {
    let baseURL: URL
    let username: String?
    let password: String?

    // Only http and https: the URL is fetched from, so a file or custom scheme is refused here.
    init?(fields: [String: String]) {
        let text = (fields[SchemaRegistryConnectionField.url] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return nil }
        baseURL = url
        let username = fields[SchemaRegistryConnectionField.username] ?? ""
        self.username = username.isEmpty ? nil : username
        password = fields[SchemaRegistryConnectionField.password]
    }
}

internal enum RegistrySchema: Sendable {
    case avro(AvroSchema)
    case protobuf(ProtobufSchema)
    // A JSON Schema value is JSON text behind the prefix; the schema adds nothing to reading it.
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
        return URLSession(configuration: configuration)
    }()

    // Read up to the cap, so a registry that never stops sending cannot fill memory.
    static let urlSessionTransport: Transport = { request in
        let (bytes, response) = try await session.bytes(for: request, delegate: SameOriginRedirects())
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes { break }
        }
        return (data, response)
    }

    func schema(id: UInt32) async throws -> RegistrySchema {
        let root: SchemaResponse = try await get(["schemas", "ids", String(id)])
        switch root.schemaType?.uppercased() ?? "AVRO" {
        case "AVRO":
            var references: [String] = []
            var seen: Set<String> = []
            try await collectReferences(root.references ?? [], into: &references, seen: &seen)
            do {
                return .avro(try AvroSchema.parse(root.schema, references: references))
            } catch let error as AvroSchemaError {
                throw SchemaRegistryError(reason: error.reason)
            }
        case "PROTOBUF":
            var references: [String] = []
            var seen: Set<String> = []
            try await collectReferences(root.references ?? [], into: &references, seen: &seen)
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

    // Depth first, each subject version once and after the ones it references, so a type is defined before its users.
    private func collectReferences(
        _ references: [SchemaReference],
        into texts: inout [String],
        seen: inout Set<String>
    ) async throws {
        for reference in references {
            let key = "\(reference.subject)@\(reference.version)"
            guard seen.insert(key).inserted else { continue }
            guard seen.count <= Self.maxReferences else {
                throw SchemaRegistryError(reason: String(localized: "The schema imports more files than TablePro reads."))
            }
            let version: SchemaResponse = try await get(["subjects", reference.subject, "versions", String(reference.version)])
            try await collectReferences(version.references ?? [], into: &texts, seen: &seen)
            texts.append(version.schema)
        }
    }

    private func get<Response: Decodable>(_ components: [String]) async throws -> Response {
        let request = request(components)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
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

    // Each component is encoded on its own: a subject such as `demo/common.proto` holds a slash.
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

// The credentials go to the registry the connection names, so a redirect elsewhere, or down to http, is not followed.
private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let from = task.originalRequest?.url, let to = request.url,
              from.scheme?.lowercased() == to.scheme?.lowercased(),
              from.host?.lowercased() == to.host?.lowercased(),
              from.port == to.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
