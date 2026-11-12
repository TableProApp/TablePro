//
//  AIChatStorage.swift
//  TablePro
//

import Foundation
import os

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
        let dir = AppStorageEnvironment.shared.applicationSupportRoot
            .appendingPathComponent("TablePro", isDirectory: true)
            .appendingPathComponent("ai_chats", isDirectory: true)
        directory = dir

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

    private static let maxFileSize = 500_000

    // Past `maxFileSize` only the last turns are written, so a longer transcript may be on disk in part.
    static let turnsKeptWhenTrimmed = 50

    func save(_ conversation: AIConversation) {
        Self.write(conversation, into: directory)
    }

    // A hop booked in applicationWillTerminate is never scheduled. Touches nothing but the `let` directory.
    nonisolated func saveSynchronously(_ conversation: AIConversation) {
        Self.write(conversation, into: directory)
    }

    nonisolated private static func write(_ conversation: AIConversation, into directory: URL) {
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).json")

        do {
            var data = try Self.encoder.encode(conversation)

            if data.count > Self.maxFileSize {
                let originalSize = data.count
                let originalCount = conversation.messages.count
                var trimmed = conversation
                trimmed.messages = Array(trimmed.messages.suffix(Self.turnsKeptWhenTrimmed))
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

    // A conversation stored before conversations carried a connection id is shown everywhere, not lost.
    static func isShown(conversationOf owner: UUID?, on connectionId: UUID?) -> Bool {
        connectionId == nil || owner == nil || owner == connectionId
    }

    // The history list needs titles only, so no stored conversation's messages are held.
    func loadSummaries(connectionId: UUID?) -> [AIConversation] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        } catch {
            Self.logger.error("Failed to list conversations: \(error.localizedDescription)")
            return []
        }

        let summaries: [AIConversation] = files
            .filter { $0.pathExtension == "json" }
            .compactMap { fileURL in
                do {
                    let data = try Data(contentsOf: fileURL)
                    let header = try Self.decoder.decode(ConversationHeader.self, from: data)
                    guard Self.isShown(conversationOf: header.connectionId, on: connectionId) else { return nil }
                    return header.summary
                } catch {
                    Self.logger.error("Failed to load conversation from \(fileURL.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) -> AIConversation? {
        let fileURL = directory.appendingPathComponent("\(id.uuidString).json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? Self.decoder.decode(AIConversation.self, from: data)
    }

    func delete(_ id: UUID) {
        let fileURL = directory.appendingPathComponent("\(id.uuidString).json")

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            Self.logger.error("Failed to delete conversation \(id): \(error.localizedDescription)")
        }
    }

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

    // Decodes the same keys as `AIConversation` and the same defaults, without `messages`.
    private struct ConversationHeader: Decodable {
        let id: UUID
        let title: String?
        let createdAt: Date
        let updatedAt: Date
        let connectionId: UUID?
        let connectionName: String?
        let schemaVersion: Int?

        var summary: AIConversation {
            AIConversation(
                id: id,
                title: title ?? "",
                createdAt: createdAt,
                updatedAt: updatedAt,
                connectionId: connectionId,
                connectionName: connectionName,
                schemaVersion: max(schemaVersion ?? 0, AIConversation.currentSchemaVersion)
            )
        }
    }
}
