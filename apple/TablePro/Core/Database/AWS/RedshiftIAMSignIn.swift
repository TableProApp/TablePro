//
//  RedshiftIAMSignIn.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// Redshift issues the user and a temporary password together, so a sign-in mints both.
struct RedshiftIAMSignIn: Sendable {
    enum Endpoint: Equatable, Sendable {
        case cluster(identifier: String, region: String)
        case serverless(workgroup: String, region: String)

        var region: String {
            switch self {
            case .cluster(_, let region), .serverless(_, let region): region
            }
        }
    }

    static let endpointFieldId = "awsRedshiftEndpoint"

    let source: String
    let databaseUser: String
    let database: String
    let fields: [String: String]
    let configuredHost: String
    let preTunnelHost: String?

    func signIn(deadline: ConnectionDeadline?) async throws -> ResolvedSignIn {
        let endpoint = try resolveEndpoint()
        let region = nonEmpty(fields["awsRegion"]) ?? endpoint.region
        return try await AWSDeadlineSession.run(within: deadline) { session in
            let credentials = try await AWSCredentialResolver.resolve(source: source, fields: fields, session: session)
            let urlRequest = try request(for: endpoint, region: region, credentials: credentials)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch {
                throw RedshiftIAMError.requestFailed(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw RedshiftIAMError.requestFailed(Self.errorMessage(in: data, for: endpoint) ?? "HTTP \(status)")
            }
            return try Self.signIn(from: data, for: endpoint)
        }
    }

    func resolveEndpoint() throws -> Endpoint {
        if let override = nonEmpty(fields[Self.endpointFieldId]) {
            let overrideHost = Self.hostName(in: override)
            guard let endpoint = Self.endpoint(forHost: overrideHost) else {
                throw RedshiftIAMError.endpointInvalid(override)
            }
            // The password goes to the host the driver dials, so it must be a forward or that endpoint itself.
            guard Self.isLoopback(configuredHost)
                || overrideHost.caseInsensitiveCompare(configuredHost) == .orderedSame
            else {
                throw RedshiftIAMError.endpointNotDialed(host: configuredHost)
            }
            return endpoint
        }
        for host in [preTunnelHost, configuredHost].compactMap({ $0 }) {
            if let endpoint = Self.endpoint(forHost: host) {
                return endpoint
            }
        }
        throw RedshiftIAMError.endpointUnresolved(host: preTunnelHost ?? configuredHost)
    }

    func request(for endpoint: Endpoint, region: String, credentials: AWSCredentials, now: Date = Date()) throws -> URLRequest {
        switch endpoint {
        case .cluster(let identifier, _):
            var parameters = ["Version": "2012-12-01", "ClusterIdentifier": identifier]
            if let databaseUser = nonEmpty(databaseUser) {
                parameters["Action"] = "GetClusterCredentials"
                parameters["DbUser"] = databaseUser
            } else {
                parameters["Action"] = "GetClusterCredentialsWithIAM"
            }
            if let database = nonEmpty(database) {
                parameters["DbName"] = database
            }
            return try AWSQueryRequest(service: "redshift", region: region, parameters: parameters)
                .signedURLRequest(credentials: credentials, now: now)
        case .serverless(let workgroup, _):
            var body = ["workgroupName": workgroup]
            if let database = nonEmpty(database) {
                body["dbName"] = database
            }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            return try AWSJSONRequest(
                service: "redshift-serverless",
                region: region,
                target: "RedshiftServerless.GetCredentials",
                body: data
            ).signedURLRequest(credentials: credentials, now: now)
        }
    }

    // Only a name AWS issued, under the region's own DNS suffix: anything else is someone else's host.
    static func endpoint(forHost host: String) -> Endpoint? {
        var name = host.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 4, !labels[0 ..< 3].contains(where: \.isEmpty) else { return nil }
        let region = labels[2]
        guard labels[4...].joined(separator: ".") == AWSPartition.resolve(region: region).dnsSuffix else { return nil }
        switch labels[3] {
        case "redshift": return .cluster(identifier: labels[0], region: region)
        case "redshift-serverless": return .serverless(workgroup: labels[0], region: region)
        default: return nil
        }
    }

    static func signIn(from data: Data, for endpoint: Endpoint) throws -> ResolvedSignIn {
        let user: String?
        let password: String?
        switch endpoint {
        case .cluster:
            let parser = ClusterCredentialsXMLParser()
            guard parser.parse(data) else { throw RedshiftIAMError.unreadableResponse }
            (user, password) = (parser.databaseUser, parser.databasePassword)
        case .serverless:
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            (user, password) = (object?["dbUser"] as? String, object?["dbPassword"] as? String)
        }
        guard let user, !user.isEmpty, let password, !password.isEmpty else {
            throw RedshiftIAMError.unreadableResponse
        }
        return ResolvedSignIn(username: user, password: password)
    }

    static func errorMessage(in data: Data, for endpoint: Endpoint) -> String? {
        switch endpoint {
        case .cluster:
            return AWSQueryErrorResponse.parse(data)?.summary
        case .serverless:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let code = (object["__type"] as? String).map { $0.split(separator: "#").last.map(String.init) ?? $0 }
            let message = object["message"] as? String ?? object["Message"] as? String
            return AWSQueryErrorResponse(code: code, message: message).summary
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespaces).lowercased()
        return ["localhost", "localhost.localdomain", "::1", "[::1]", "0.0.0.0"].contains(normalized)
            || normalized.hasPrefix("127.")
    }

    private static func hostName(in value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        }
        if let slash = text.firstIndex(of: "/") {
            text = String(text[..<slash])
        }
        if let colon = text.lastIndex(of: ":") {
            text = String(text[..<colon])
        }
        return text
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension RedshiftIAMSignIn {
    @MainActor
    init(connection: DatabaseConnection, source: String, fields: [String: String]) {
        self.init(
            source: source,
            databaseUser: ConnectionCredentialResolver.resolveUsername(for: connection),
            database: connection.database,
            fields: fields,
            configuredHost: connection.host,
            preTunnelHost: connection.preTunnelHost
        )
    }
}

enum RedshiftIAMError: LocalizedError, Equatable {
    case endpointUnresolved(host: String)
    case endpointInvalid(String)
    case endpointNotDialed(host: String)
    case requestFailed(String)
    case unreadableResponse

    var errorDescription: String? {
        switch self {
        case .endpointUnresolved(let host):
            return String(
                format: String(localized: """
                    TablePro cannot tell which Redshift cluster or workgroup "%@" is. Set Host to the \
                    endpoint AWS issued, such as my-cluster.abc123.us-east-1.redshift.amazonaws.com, or \
                    enter that endpoint as the Redshift Endpoint when you connect through a port forward.
                    """),
                host
            )
        case .endpointInvalid(let value):
            return String(
                format: String(localized: "\"%@\" is not a Redshift cluster or Serverless workgroup endpoint."),
                value
            )
        case .endpointNotDialed(let host):
            return String(
                format: String(localized: """
                    The Redshift Endpoint applies only when Host is a local port forward or that same \
                    endpoint, and "%@" is neither.
                    """),
                host
            )
        case .requestFailed(let message):
            return String(format: String(localized: "AWS did not issue Redshift credentials: %@"), message)
        case .unreadableResponse:
            return String(localized: "AWS answered without the Redshift user and password.")
        }
    }
}

private final class ClusterCredentialsXMLParser: NSObject, XMLParserDelegate {
    var databaseUser: String?
    var databasePassword: String?

    private var buffer = ""

    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        return parser.parse()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "DbUser": databaseUser = value
        case "DbPassword": databasePassword = value
        default: break
        }
        buffer = ""
    }
}
