//
//  LastOpenConnectionsStorage.swift
//  TablePro
//
//  Records which connections had open windows at last quit so the
//  "Reopen Last Session" startup behavior can recover after a crash,
//  where AppKit's window-restoration archive is never written.
//

import Foundation
import os

@MainActor
final class LastOpenConnectionsStorage {
    static let shared = LastOpenConnectionsStorage()

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LastOpenConnections")

    // The legacy file keeps the [UUID] format older builds read, holding only connections that
    // reconnect, so an older build never dials one the user canceled.
    private let legacyURL: URL
    private let sessionURL: URL
    private var isSealed = false

    private convenience init() {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        self.init(directory: appSupport.appendingPathComponent("TablePro", isDirectory: true))
    }

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacyURL = directory.appendingPathComponent("LastOpenConnections.json")
        sessionURL = directory.appendingPathComponent("LastSession.json")
    }

    // A missing legacy list means an older build removed it, so this never leaves the session alone:
    // a first save writes the list before the session, and every later save writes the session first
    // so one cut short leaves the session the newer file. The list is written even when empty.
    func save(_ session: LastSession) {
        guard !isSealed else { return }
        guard !session.connections.isEmpty else {
            clear()
            return
        }
        let reconnecting = session.reconnectingIds
        let hasLegacy = FileManager.default.fileExists(atPath: legacyURL.path)
        if !hasLegacy {
            write(reconnecting, to: legacyURL)
        }
        write(session, to: sessionURL)
        if hasLegacy {
            write(reconnecting, to: legacyURL)
        }
    }

    // An older build rewrites only the legacy file, so when the two disagree the newer one is current.
    func load() -> LastSession {
        guard let legacy = read([UUID].self, from: legacyURL) else { return .empty }
        let legacySession = LastSession(
            connections: legacy.map { LastSession.Connection(id: $0, reconnects: true) },
            shownConnectionId: nil
        )
        guard let session = read(LastSession.self, from: sessionURL) else { return legacySession }
        guard session.reconnectingIds != legacy else { return session }
        return modificationDate(of: legacyURL) > modificationDate(of: sessionURL) ? legacySession : session
    }

    func clear() {
        remove(legacyURL)
        remove(sessionURL)
    }

    // The quit save is the last word: AppKit closes the windows after it, and no coordinator may
    // exist to have flagged termination, so those closes would otherwise save an empty session.
    func seal() {
        isSealed = true
    }

    private func write(_ value: some Encodable, to url: URL) {
        do {
            let data = try JSONEncoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Failed to save last open connections: \(error.publicLogShape, privacy: .public)")
        }
    }

    private func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch {
            Self.logger.error("Failed to load last open connections: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    private func modificationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private func remove(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
