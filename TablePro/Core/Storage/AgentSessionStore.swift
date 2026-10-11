//
//  AgentSessionStore.swift
//  TablePro
//

import Foundation
import os

/// Where agent sessions live between launches, on this Mac only.
///
/// Device-local on purpose. A transcript carries query results, schema and whatever the user typed
/// about their data, and none of that is declared in the CloudKit production schema, so writing it
/// there is both a product decision nobody has made and a record type the server would reject.
///
/// Not an actor. Restore has to finish before the first window exists, or a window that opens while
/// the load is suspended finds no sessions, mints one, and is then joined by the stored one: two
/// sessions on one conversation, both persisted, both in the rail. Reading one small file
/// synchronously closes that by construction. Measured on the record shape it reads: 0.08ms for ten
/// sessions and 0.6ms for two hundred, against a launch budget in the hundreds of milliseconds.
internal struct AgentSessionStore: Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AgentSessionStore")

    private let fileURL: URL

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    internal init(directory: URL? = nil) {
        let root = directory ?? AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
        fileURL = root.appendingPathComponent("AgentSessions.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Could not create the agent session directory: \(error.localizedDescription)")
        }
    }

    internal func load() -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode([AgentSessionRecord].self, from: data)
        } catch {
            Self.logger.error("Could not read agent sessions: \(error.localizedDescription)")
            return []
        }
    }

    internal func save(_ records: [AgentSessionRecord]) {
        do {
            let data = try Self.encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Could not write agent sessions: \(error.localizedDescription)")
        }
    }
}
