//
//  AIChatStorage.swift
//  TablePro
//
//  File-based persistence for AI chat conversations.
//

import Foundation
import os

/// Manages persistent storage of AI chat conversations as individual JSON files
actor AIChatStorage {
    static let shared = AIChatStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "AIChatStorage")

    private let directory: URL

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
        self.init(directory: AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("ai_chats", isDirectory: true))
    }

    /// Injectable so a test can scope reads against a throwaway directory instead of the chat
    /// history of whoever is running it.
    internal init(directory dir: URL) {
        directory = dir

        // Create directory inline since actor init is nonisolated
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: dir.path
            )
        } catch {
            Self.logger.error("Failed to create ai_chats directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Public Methods

    /// Maximum encoded size for a single conversation file (500 KB)
    private static let maxFileSize = 500_000

    /// Maximum number of messages to keep after trimming
    private static let trimmedMessageCount = 50

    /// Save a conversation to disk
    func save(_ conversation: AIConversation) {
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).json")

        do {
            var data = try Self.encoder.encode(conversation)

            if data.count > Self.maxFileSize {
                let originalSize = data.count
                let originalCount = conversation.messages.count
                var trimmed = conversation
                trimmed.messages = Array(trimmed.messages.suffix(Self.trimmedMessageCount))
                let dropped = originalCount - trimmed.messages.count
                data = try Self.encoder.encode(trimmed)
                Self.logger.warning(
                    """
                    Trimmed conversation \(conversation.id, privacy: .public): \
                    \(originalSize) bytes exceeded \(Self.maxFileSize), \
                    dropped \(dropped) of \(originalCount) messages, kept \(trimmed.messages.count)
                    """
                )
            }

            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save conversation \(conversation.id): \(error.localizedDescription)")
        }
    }

    /// Quit only. `applicationWillTerminate` has no time for an actor hop that may never be
    /// scheduled before the process exits, so the terminate path writes on the calling thread. The
    /// trimming above is skipped: the caller is already out of time, and a turn on disk that is
    /// larger than the cap is still readable, while no turn on disk is the bug this exists to fix.
    nonisolated func saveSync(_ conversation: AIConversation) {
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).json")
        do {
            let data = try Self.encoder.encode(conversation)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.logger.error("Failed to save conversation \(conversation.id) at terminate: \(error.localizedDescription)")
        }
    }

    /// Load all conversations, sorted by updatedAt descending
    func loadAll() -> [AIConversation] {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )

            let conversations: [AIConversation] = files
                .filter { $0.pathExtension == "json" }
                .compactMap { fileURL in
                    do {
                        let data = try Data(contentsOf: fileURL)
                        return try Self.decoder.decode(AIConversation.self, from: data)
                    } catch {
                        Self.logger.error("Failed to load conversation from \(fileURL.lastPathComponent): \(error.localizedDescription)")
                        return nil
                    }
                }

            return conversations.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Self.logger.error("Failed to list conversations: \(error.localizedDescription)")
            return []
        }
    }

    /// Load one conversation by ID
    func load(id: UUID) -> AIConversation? {
        let fileURL = directory.appendingPathComponent("\(id.uuidString).json")
        do {
            let data = try Data(contentsOf: fileURL)
            return try Self.decoder.decode(AIConversation.self, from: data)
        } catch {
            Self.logger.error("Failed to load conversation \(id): \(error.localizedDescription)")
            return nil
        }
    }

    /// Conversations a session may list: its own connection's, plus the orphans left by records
    /// written before the connection id existed. A nil id lists the orphans alone.
    func loadAll(connectionId: UUID?) -> [AIConversation] {
        loadAll().filter { $0.connectionId == connectionId || $0.isOrphan }
    }

    /// Delete a conversation by ID
    func delete(_ id: UUID) {
        let fileURL = directory.appendingPathComponent("\(id.uuidString).json")

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Failed to delete conversation \(id): \(error.localizedDescription)")
        }
    }

    /// Delete all conversations
    func deleteAll() {
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
            for file in files where file.pathExtension == "json" {
                try FileManager.default.removeItem(at: file)
            }
        } catch {
            Self.logger.error("Failed to delete all conversations: \(error.localizedDescription)")
        }
    }
}
