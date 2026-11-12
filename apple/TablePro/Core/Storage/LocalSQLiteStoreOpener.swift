import Foundation
import os
import SQLite3

struct SetAsideDamagedStore: Sendable, Equatable {
    let storeURL: URL
    let setAsideURL: URL
}

enum LocalSQLiteStoreOpening {
    case opened(OpaquePointer, setAside: SetAsideDamagedStore?)
    case unavailable
}

// sqlite3_open succeeds on a damaged file, so quick_check runs before anything reads or writes it.
enum LocalSQLiteStoreOpener {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LocalSQLiteStore")
    private static let busyTimeoutMilliseconds: Int32 = 3_000

    private enum Verdict {
        case healthy(OpaquePointer)
        case damaged(String)
        case unavailable(String)
    }

    static func open(at url: URL, now: Date = Date()) -> LocalSQLiteStoreOpening {
        let path = url.path(percentEncoded: false)
        switch openChecked(path: path) {
        case .healthy(let handle):
            return .opened(handle, setAside: nil)
        case .unavailable(let reason):
            logger.error("Local store could not be opened: \(reason, privacy: .public)")
            return .unavailable
        case .damaged(let reason):
            logger.fault("Local store is damaged: \(reason, privacy: .public)")
            guard let moved = setAside(url, now: now) else { return .unavailable }
            guard case .healthy(let handle) = openChecked(path: path) else {
                logger.error("A fresh store could not be opened after setting the damaged one aside")
                return .unavailable
            }
            return .opened(handle, setAside: moved)
        }
    }

    private static func isDamage(_ resultCode: Int32) -> Bool {
        let primary = resultCode & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    static func setAsideURL(for url: URL, at date: Date, fileManager: FileManager = .default) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)

        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        var attempt = 0
        while true {
            let marker = attempt == 0 ? stamp : "\(stamp)-\(attempt)"
            let name = pathExtension.isEmpty
                ? "\(stem).damaged-\(marker)"
                : "\(stem).damaged-\(marker).\(pathExtension)"
            let candidate = directory.appendingPathComponent(name)
            let candidatePath = candidate.path(percentEncoded: false)
            let taken = ["", "-wal", "-shm"].contains { fileManager.fileExists(atPath: candidatePath + $0) }
            if !taken { return candidate }
            attempt += 1
        }
    }

    // Every copy setAsideURL(for:) ever named for this store, with its -wal and -shm.
    @discardableResult
    static func removeSetAsideCopies(of url: URL, fileManager: FileManager = .default) -> Bool {
        let directory = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + ".damaged-"
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else {
            return false
        }
        var removedAll = true
        for name in names where name.hasPrefix(prefix) {
            do {
                try fileManager.removeItem(at: directory.appendingPathComponent(name))
            } catch {
                logger.error("Could not delete a set-aside store: \(error.publicLogShape, privacy: .public)")
                removedAll = false
            }
        }
        return removedAll
    }

    private static func openChecked(path: String) -> Verdict {
        var handle: OpaquePointer?
        let openResult = sqlite3_open(path, &handle)
        guard openResult == SQLITE_OK, let handle else {
            let reason = String(cString: sqlite3_errstr(openResult))
            sqlite3_close_v2(handle)
            return isDamage(openResult) ? .damaged(reason) : .unavailable(reason)
        }
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)

        let verdict = quickCheck(handle)
        if case .healthy = verdict {
            return verdict
        }
        sqlite3_close_v2(handle)
        return verdict
    }

    private static func quickCheck(_ handle: OpaquePointer) -> Verdict {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let prepareResult = sqlite3_prepare_v2(handle, "PRAGMA quick_check(1);", -1, &statement, nil)
        guard prepareResult == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(handle))
            return isDamage(prepareResult) ? .damaged(reason) : .unavailable(reason)
        }

        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            let reason = String(cString: sqlite3_errmsg(handle))
            return isDamage(stepResult) ? .damaged(reason) : .unavailable(reason)
        }
        let report = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        return report == "ok" ? .healthy(handle) : .damaged(report)
    }

    // The -wal moves first: SQLite deletes a -wal it finds beside an empty database.
    private static func setAside(_ url: URL, now: Date) -> SetAsideDamagedStore? {
        let fileManager = FileManager.default
        let path = url.path(percentEncoded: false)
        let destination = setAsideURL(for: url, at: now, fileManager: fileManager)
        let destinationPath = destination.path(percentEncoded: false)

        let walPath = path + "-wal"
        let walDestinationPath = destinationPath + "-wal"
        let movedWal = fileManager.fileExists(atPath: walPath)
        if movedWal {
            do {
                try fileManager.moveItem(atPath: walPath, toPath: walDestinationPath)
            } catch {
                logger.error("Could not set aside a damaged store's log: \(error.publicLogShape, privacy: .public)")
                return nil
            }
        }

        do {
            try fileManager.moveItem(atPath: path, toPath: destinationPath)
        } catch {
            logger.error("Could not set aside a damaged store: \(error.publicLogShape, privacy: .public)")
            if movedWal {
                try? fileManager.moveItem(atPath: walDestinationPath, toPath: walPath)
            }
            return nil
        }

        let shmPath = path + "-shm"
        if fileManager.fileExists(atPath: shmPath),
           (try? fileManager.moveItem(atPath: shmPath, toPath: destinationPath + "-shm")) == nil {
            try? fileManager.removeItem(atPath: shmPath)
        }

        logger.fault("Set a damaged store aside as \(destination.lastPathComponent, privacy: .private(mask: .hash))")
        return SetAsideDamagedStore(storeURL: url, setAsideURL: destination)
    }
}
