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

    private static let logger = Logger(subsystem: "com.TablePro", category: "PasswordSource")

    private enum CodingKeys: String, CodingKey {
        case kind, path, variable, shell
    }

    private enum Kind: String {
        case file, env, command
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
