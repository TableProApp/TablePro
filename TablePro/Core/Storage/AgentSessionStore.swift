//
//  AgentSessionStore.swift
//  TablePro
//

import Foundation
import os

/// What a session was, written so the rail can list it again after a relaunch.
///
/// The transcript is not in here. `AIChatStorage` already owns conversations, keyed by id, and a
/// second copy of the turns would be a second thing to keep in step: this record points at the
/// conversation instead.
internal struct AgentSessionRecord: Codable, Equatable, Sendable, Identifiable {
    internal let id: UUID
    internal let connectionId: UUID
    internal var connectionName: String
    internal var title: String?
    internal var status: AgentSessionStatus
    internal var conversationId: UUID?
    internal var createdAt: Date
    internal var updatedAt: Date

    /// A record left `running` was not written by a clean quit, because the terminate hook marks a
    /// streaming session `failed` before the process goes away. So `running` on disk means the
    /// process died, and the honest status to restore it under is `failed`.
    internal var restoredStatus: AgentSessionStatus {
        switch status {
        case .running, .queued, .waitingOnYou:
            return .failed
        case .idle:
            return .stopped
        case .stopped, .failed:
            return status
        }
    }
}

/// Sessions are device-local, so this is a plain JSON file rather than anything that syncs. A
/// transcript is not synced either (`AIChatStorage` writes to Application Support), and a session
/// that appeared on another Mac would name a window and a connection state that Mac does not have.
internal actor AgentSessionStore {
    internal static let shared = AgentSessionStore()

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

    private init() {
        self.init(fileURL: AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("agent_sessions.json"))
    }

    /// Injectable for the same reason `AIChatStorage`'s directory is: a test that exercised restore
    /// would otherwise rewrite the session list of whoever is running it.
    internal init(fileURL: URL) {
        self.fileURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create session store directory: \(error.localizedDescription)")
        }
    }

    /// Reads on the calling thread, so the registry can restore before it answers its first
    /// question rather than racing a task that fills the list afterwards. Nothing but `fileURL` is
    /// touched, and that is a `let`. The file holds one small record per session, no transcripts,
    /// so the read is not worth an actor hop and the correctness of not having one is worth a lot.
    nonisolated internal func load() -> [AgentSessionRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode([AgentSessionRecord].self, from: data)
        } catch {
            Self.logger.error("Failed to load agent sessions: \(error.localizedDescription)")
            return []
        }
    }

    /// Written whole rather than per record. The list is small, one write is atomic, and a
    /// per-record file would leave a removed session's file behind on any path that forgot it.
    internal func save(_ records: [AgentSessionRecord]) {
        do {
            let data = try Self.encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save agent sessions: \(error.localizedDescription)")
        }
    }

    /// Terminate has no time for an actor hop that may not be scheduled before the process exits, so
    /// the quit path writes on the calling thread.
    nonisolated internal func saveSync(_ records: [AgentSessionRecord]) {
        do {
            let data = try Self.encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save agent sessions at terminate: \(error.localizedDescription)")
        }
    }
}
