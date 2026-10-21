//
//  VaultDatabaseRole.swift
//  TablePro
//

import Foundation

struct VaultDatabaseRole: Hashable, Sendable {
    // Nil reads VAULT_ADDR at sign-in, the way the vault CLI does.
    var address: String?
    var mount: String
    var role: String
    var auth: VaultAuthMethod

    init(address: String? = nil, mount: String, role: String, auth: VaultAuthMethod = .token) {
        self.address = address
        self.mount = mount
        self.role = role
        self.auth = auth
    }

    var credentialsPath: String {
        "\(Self.trimmedPath(mount))/creds/\(Self.trimmedPath(role))"
    }

    static func trimmedPath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
    }
}

enum VaultAuthMethod: Hashable, Sendable {
    // VAULT_TOKEN, then ~/.vault-token.
    case token
    // The secret ID is read from a file, as Vault Agent's secret_id_file_path does, so no secret lands in the profile.
    case appRole(mount: String, roleId: String, secretIdPath: String)
    // An empty role uses the auth mount's default_role.
    case oidc(mount: String, role: String)

    static let defaultAppRoleMount = "approle"
    static let defaultOIDCMount = "oidc"
}

extension VaultDatabaseRole: Codable {
    private enum CodingKeys: String, CodingKey {
        case address, mount, role, auth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try container.decodeIfPresent(String.self, forKey: .address)?
            .trimmingCharacters(in: .whitespaces)
        self.address = address?.isEmpty == false ? address : nil
        mount = try container.decode(String.self, forKey: .mount)
        role = try container.decode(String.self, forKey: .role)
        auth = try container.decodeIfPresent(VaultAuthMethod.self, forKey: .auth) ?? .token
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(address, forKey: .address)
        try container.encode(mount, forKey: .mount)
        try container.encode(role, forKey: .role)
        try container.encode(auth, forKey: .auth)
    }
}

extension VaultAuthMethod: Codable {
    private enum CodingKeys: String, CodingKey {
        case method, mount, roleId, secretIdPath, role
    }

    private enum Method: String {
        case token, approle, oidc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decode(String.self, forKey: .method)
        switch method {
        case Method.token.rawValue:
            self = .token
        case Method.approle.rawValue:
            self = .appRole(
                mount: try container.decodeIfPresent(String.self, forKey: .mount) ?? Self.defaultAppRoleMount,
                roleId: try container.decode(String.self, forKey: .roleId),
                secretIdPath: try container.decode(String.self, forKey: .secretIdPath)
            )
        case Method.oidc.rawValue:
            self = .oidc(
                mount: try container.decodeIfPresent(String.self, forKey: .mount) ?? Self.defaultOIDCMount,
                role: try container.decodeIfPresent(String.self, forKey: .role) ?? ""
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .method,
                in: container,
                debugDescription: "Unknown Vault auth method: \(method)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .token:
            try container.encode(Method.token.rawValue, forKey: .method)
        case let .appRole(mount, roleId, secretIdPath):
            try container.encode(Method.approle.rawValue, forKey: .method)
            try container.encode(mount, forKey: .mount)
            try container.encode(roleId, forKey: .roleId)
            try container.encode(secretIdPath, forKey: .secretIdPath)
        case let .oidc(mount, role):
            try container.encode(Method.oidc.rawValue, forKey: .method)
            try container.encode(mount, forKey: .mount)
            try container.encode(role, forKey: .role)
        }
    }
}
