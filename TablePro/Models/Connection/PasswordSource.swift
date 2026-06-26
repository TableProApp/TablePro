//
//  PasswordSource.swift
//  TablePro
//

import Foundation
import os

/// Declares where a connection's password comes from when it is not stored in the Keychain.
/// Resolved at connect time from a file, an environment variable, or the stdout of a shell command.
enum PasswordSource: Codable, Hashable, Sendable {
    case file(path: String)
    case env(variable: String)
    case command(shell: String)
    case onePassword(reference: String)
    case vault(path: String, field: String)
    case awsSecretsManager(secretId: String, jsonKey: String?)

    private static let logger = Logger(subsystem: "com.TablePro", category: "PasswordSource")

    private enum CodingKeys: String, CodingKey {
        case kind, path, variable, shell, reference, field, secretId, jsonKey
    }

    private enum Kind: String {
        case file, env, command, onePassword, vault, awsSecretsManager
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.file.rawValue:
            self = .file(path: try container.decode(String.self, forKey: .path))
        case Kind.env.rawValue:
            self = .env(variable: try container.decode(String.self, forKey: .variable))
        case Kind.command.rawValue:
            self = .command(shell: try container.decode(String.self, forKey: .shell))
        case Kind.onePassword.rawValue:
            self = .onePassword(reference: try container.decode(String.self, forKey: .reference))
        case Kind.vault.rawValue:
            self = .vault(
                path: try container.decode(String.self, forKey: .path),
                field: try container.decode(String.self, forKey: .field)
            )
        case Kind.awsSecretsManager.rawValue:
            self = .awsSecretsManager(
                secretId: try container.decode(String.self, forKey: .secretId),
                jsonKey: try container.decodeIfPresent(String.self, forKey: .jsonKey)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown passwordSource kind: \(kind)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .file(path):
            try container.encode(Kind.file.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
        case let .env(variable):
            try container.encode(Kind.env.rawValue, forKey: .kind)
            try container.encode(variable, forKey: .variable)
        case let .command(shell):
            try container.encode(Kind.command.rawValue, forKey: .kind)
            try container.encode(shell, forKey: .shell)
        case let .onePassword(reference):
            try container.encode(Kind.onePassword.rawValue, forKey: .kind)
            try container.encode(reference, forKey: .reference)
        case let .vault(path, field):
            try container.encode(Kind.vault.rawValue, forKey: .kind)
            try container.encode(path, forKey: .path)
            try container.encode(field, forKey: .field)
        case let .awsSecretsManager(secretId, jsonKey):
            try container.encode(Kind.awsSecretsManager.rawValue, forKey: .kind)
            try container.encode(secretId, forKey: .secretId)
            try container.encodeIfPresent(jsonKey, forKey: .jsonKey)
        }
    }

    /// Decodes a password source from a connection container, treating a present-but-malformed
    /// entry as absent so one bad connection cannot fail loading of the whole store.
    static func resilientlyDecoded<Key>(
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> PasswordSource? {
        do {
            return try container.decodeIfPresent(PasswordSource.self, forKey: key)
        } catch {
            logger.warning("Ignoring malformed passwordSource in a connection")
            return nil
        }
    }
}
