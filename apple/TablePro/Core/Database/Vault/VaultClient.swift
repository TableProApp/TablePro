//
//  VaultClient.swift
//  TablePro
//

import Foundation

struct VaultEndpoint: Hashable, Sendable {
    let address: URL
    let namespace: String?

    static func resolve(address: String?, environment: [String: String]) throws -> VaultEndpoint {
        let configured = address?.trimmingCharacters(in: .whitespaces)
        let raw = configured?.isEmpty == false ? configured : environment["VAULT_ADDR"]?.trimmingCharacters(in: .whitespaces)
        guard let raw, !raw.isEmpty else { throw VaultError.noAddress }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false
        else {
            throw VaultError.invalidAddress(raw)
        }
        let namespace = environment["VAULT_NAMESPACE"]?.trimmingCharacters(in: .whitespaces)
        return VaultEndpoint(address: url, namespace: namespace?.isEmpty == false ? namespace : nil)
    }

    func url(forAPIPath path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else { return nil }
        let base = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }
        components.percentEncodedPath = base + "/v1/" + encodedPath.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}

protocol VaultTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionVaultTransport: VaultTransport {
    static let shared = URLSessionVaultTransport()

    private let session: URLSession

    init(timeout: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

struct VaultRequestError: Error, Equatable {
    let status: Int
    let messages: [String]

    var isPermissionDenied: Bool { status == 403 }

    // Vault wraps several causes as "2 errors occurred:\n\t* permission denied\n\t* invalid token".
    var message: String {
        let lines = messages.flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasSuffix("errors occurred:") && !$0.hasSuffix("error occurred:") }
            .map { $0.hasPrefix("* ") ? String($0.dropFirst(2)) : $0 }
        return lines.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : lines.joined(separator: "; ")
    }
}

struct VaultLeasedCredential: Equatable, Sendable {
    let leaseId: String
    let leaseDuration: Duration
    let renewable: Bool
    let username: String
    let password: String
}

struct VaultTokenGrant: Equatable, Sendable {
    let token: String
    // Nil when the token never expires (a ttl of 0).
    let ttl: Duration?
    let renewable: Bool
}

struct VaultClient: Sendable {
    let endpoint: VaultEndpoint
    let transport: any VaultTransport

    func readCredentials(path: String, token: String) async throws -> VaultLeasedCredential {
        let reply: SecretReply = try await call("GET", path, token: token)
        guard let username = reply.data?["username"], let password = reply.data?["password"],
              !username.isEmpty, !password.isEmpty, !reply.leaseId.isEmpty
        else {
            throw VaultError.malformedResponse
        }
        return VaultLeasedCredential(
            leaseId: reply.leaseId,
            leaseDuration: .seconds(reply.leaseDuration),
            renewable: reply.renewable,
            username: username,
            password: password
        )
    }

    func renewLease(id: String, increment: Duration, token: String, timeout: Duration? = nil) async throws -> Duration {
        let reply: LeaseReply = try await call(
            "PUT", "sys/leases/renew", token: token,
            body: ["lease_id": id, "increment": Int(increment.components.seconds)],
            timeout: timeout
        )
        return .seconds(reply.leaseDuration)
    }

    func revokeLease(id: String, token: String) async throws {
        let _: EmptyReply = try await call("PUT", "sys/leases/revoke", token: token, body: ["lease_id": id])
    }

    func lookupSelf(token: String) async throws -> VaultTokenGrant {
        let reply: LookupReply = try await call("GET", "auth/token/lookup-self", token: token)
        let ttl = reply.data.ttl ?? 0
        return VaultTokenGrant(token: token, ttl: ttl > 0 ? .seconds(ttl) : nil, renewable: reply.data.renewable ?? false)
    }

    func renewSelf(token: String, increment: Duration, timeout: Duration? = nil) async throws -> VaultTokenGrant {
        let reply: AuthReply = try await call(
            "POST", "auth/token/renew-self", token: token,
            body: ["increment": "\(increment.components.seconds)s"],
            timeout: timeout
        )
        return reply.grant
    }

    func appRoleLogin(mount: String, roleId: String, secretId: String) async throws -> VaultTokenGrant {
        let reply: AuthReply = try await call(
            "POST", "auth/\(VaultDatabaseRole.trimmedPath(mount))/login", token: nil,
            body: ["role_id": roleId, "secret_id": secretId]
        )
        return reply.grant
    }

    func oidcAuthURL(mount: String, role: String, redirectURI: String, clientNonce: String) async throws -> URL {
        var body = ["redirect_uri": redirectURI, "client_nonce": clientNonce]
        if !role.isEmpty { body["role"] = role }
        let reply: AuthURLReply = try await call(
            "POST", "auth/\(VaultDatabaseRole.trimmedPath(mount))/oidc/auth_url", token: nil, body: body
        )
        guard let raw = reply.data.authUrl, !raw.isEmpty, let url = URL(string: raw) else {
            throw VaultError.oidcFailed(String(localized: """
                Vault returned no sign-in page. The OIDC role must allow the redirect URI \
                http://localhost:8250/oidc/callback.
                """))
        }
        return url
    }

    func oidcCallback(mount: String, state: String, code: String, clientNonce: String) async throws -> VaultTokenGrant {
        let reply: AuthReply = try await call(
            "GET", "auth/\(VaultDatabaseRole.trimmedPath(mount))/oidc/callback", token: nil,
            query: [
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code", value: code),
                URLQueryItem(name: "client_nonce", value: clientNonce)
            ]
        )
        return reply.grant
    }

    // MARK: - Transport

    private func call<Reply: Decodable>(
        _ method: String,
        _ path: String,
        token: String?,
        body: [String: Any]? = nil,
        query: [URLQueryItem] = [],
        timeout: Duration? = nil
    ) async throws -> Reply {
        guard let url = endpoint.url(forAPIPath: path, query: query) else {
            throw VaultError.invalidAddress(endpoint.address.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = max(1, TimeInterval(timeout.components.seconds))
        }
        request.setValue("true", forHTTPHeaderField: "X-Vault-Request")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Vault-Token") }
        if let namespace = endpoint.namespace { request.setValue(namespace, forHTTPHeaderField: "X-Vault-Namespace") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VaultError.unreachable(endpoint.address.absoluteString, error.localizedDescription)
        }

        guard (200 ..< 300).contains(response.statusCode) else {
            let messages = (try? Self.decoder.decode(ErrorReply.self, from: data))?.errors ?? []
            throw VaultRequestError(status: response.statusCode, messages: messages)
        }
        if Reply.self == EmptyReply.self, let empty = EmptyReply() as? Reply { return empty }
        do {
            return try Self.decoder.decode(Reply.self, from: data)
        } catch {
            throw VaultError.malformedResponse
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private struct EmptyReply: Decodable {}

    private struct ErrorReply: Decodable {
        let errors: [String]?
    }

    private struct SecretReply: Decodable {
        let leaseId: String
        let leaseDuration: Int64
        let renewable: Bool
        let data: [String: String]?
    }

    private struct LeaseReply: Decodable {
        let leaseDuration: Int64
    }

    private struct LookupReply: Decodable {
        struct Data: Decodable {
            let ttl: Int64?
            let renewable: Bool?
        }

        let data: Data
    }

    private struct AuthReply: Decodable {
        struct Auth: Decodable {
            let clientToken: String
            let leaseDuration: Int64?
            let renewable: Bool?
        }

        let auth: Auth

        var grant: VaultTokenGrant {
            let ttl = auth.leaseDuration ?? 0
            return VaultTokenGrant(
                token: auth.clientToken,
                ttl: ttl > 0 ? .seconds(ttl) : nil,
                renewable: auth.renewable ?? false
            )
        }
    }

    private struct AuthURLReply: Decodable {
        struct Data: Decodable {
            let authUrl: String?
        }

        let data: Data
    }
}
