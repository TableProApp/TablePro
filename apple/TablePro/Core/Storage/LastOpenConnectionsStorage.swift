//
//  LastOpenConnectionsStorage.swift
//  TablePro
//

import Foundation

// Reopen Last Session reads this after a crash too, when AppKit never wrote its window-restoration archive.
@MainActor
final class LastOpenConnectionsStorage {
    static let shared = LastOpenConnectionsStorage()

    // The legacy file keeps the [UUID] format older builds read, holding only connections that
    // reconnect, so an older build never dials one the user canceled.
    private let legacyFile: JSONFileStore<[UUID]>
    private let sessionFile: JSONFileStore<LastSession>
    private var isSealed = false
    // What both files hold, known only after every write of a save returned.
    private var lastSaved: LastSession?

    private convenience init() {
        let appSupport = AppStorageEnvironment.shared.applicationSupportRoot
        self.init(directory: appSupport.appendingPathComponent("TablePro", isDirectory: true))
    }

    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        legacyFile = JSONFileStore(url: directory.appendingPathComponent("LastOpenConnections.json"))
        sessionFile = JSONFileStore(url: directory.appendingPathComponent("LastSession.json"))
    }

    // A missing legacy list means an older build removed it, so this never leaves the session alone:
    // a first save writes the list before the session, and every later save writes the session first
    // so one cut short leaves the session the newer file. The list is written even when empty.
    // A key window and nine other callers save; the same session with both files in place writes nothing.
    func save(_ session: LastSession) {
        guard !isSealed else { return }
        guard !session.connections.isEmpty else {
            clear()
            return
        }
        let hasLegacy = legacyFile.exists
        if session == lastSaved, hasLegacy, sessionFile.exists { return }
        lastSaved = nil
        let reconnecting = session.reconnectingIds
        var wroteAll = true
        if !hasLegacy {
            wroteAll = write(reconnecting, to: legacyFile) && wroteAll
        }
        wroteAll = write(session, to: sessionFile) && wroteAll
        if hasLegacy {
            wroteAll = write(reconnecting, to: legacyFile) && wroteAll
        }
        if wroteAll {
            lastSaved = session
        }
    }

    private func write<Value: Encodable>(_ value: Value, to file: JSONFileStore<Value>) -> Bool {
        do {
            try file.write(value)
            return true
        } catch {
            return false
        }
    }

    // An older build rewrites only the legacy file, so when the two disagree the newer one is current.
    func load() -> LastSession {
        guard let legacy = legacyFile.read().value else { return .empty }
        let legacySession = LastSession(
            connections: legacy.map { LastSession.Connection(id: $0, reconnects: true) },
            shownConnectionId: nil
        )
        guard let session = sessionFile.read().value else { return legacySession }
        guard session.reconnectingIds != legacy else { return session }
        return modificationDate(of: legacyFile.url) > modificationDate(of: sessionFile.url) ? legacySession : session
    }

    func clear() {
        lastSaved = nil
        try? legacyFile.remove()
        try? sessionFile.remove()
    }

    // The quit save is the last word: AppKit closes the windows after it, and no coordinator may
    // exist to have flagged termination, so those closes would otherwise save an empty session.
    func seal() {
        isSealed = true
    }

    private func modificationDate(of url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}
