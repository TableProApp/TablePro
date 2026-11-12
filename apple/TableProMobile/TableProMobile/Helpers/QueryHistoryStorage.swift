import Foundation
import os

nonisolated struct QueryHistoryItem: Identifiable, Codable, Hashable {
    let id: UUID
    let query: String
    let timestamp: Date
    let connectionId: UUID
    let wasSuccessful: Bool
    let errorMessage: String?

    init(
        id: UUID = UUID(),
        query: String,
        timestamp: Date = Date(),
        connectionId: UUID,
        wasSuccessful: Bool = true,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.query = query
        self.timestamp = timestamp
        self.connectionId = connectionId
        self.wasSuccessful = wasSuccessful
        self.errorMessage = errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        query = try container.decode(String.self, forKey: .query)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        connectionId = try container.decode(UUID.self, forKey: .connectionId)
        wasSuccessful = try container.decodeIfPresent(Bool.self, forKey: .wasSuccessful) ?? true
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

// One per library. The file is read once; every later read comes from the copy in memory, which takes a change only
// once the file holds it. The lock orders a save running off the main actor with a delete or clear on it.
nonisolated final class QueryHistoryStorage: Sendable {
    private static let maxEntries = 200
    // The whole list is encoded on every save, so its text is held to this many bytes; the newest entry always stays,
    // and no entry is ever cut, since running part of a script from history would run part of it.
    static let maxTextBytes = 2 * 1_024 * 1_024
    private static let logger = Logger(subsystem: "com.TablePro", category: "QueryHistoryStorage")

    private let directory: URL
    private let state = OSAllocatedUnfairLock(initialState: State())

    private nonisolated struct State {
        // Nil until the file has been read.
        var items: [QueryHistoryItem]?
        // Counts the writes, so a list read before a later write is never shown over it.
        var generation = 0
    }

    nonisolated struct Listed: Sendable {
        let items: [QueryHistoryItem]
        let generation: Int
    }

    init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL {
        directory.appendingPathComponent("query-history.json")
    }

    @discardableResult
    func save(_ item: QueryHistoryItem) -> Bool {
        record(item) != nil
    }

    // The connection's list once the item is saved, read from memory; nil when nothing was saved.
    func record(_ item: QueryHistoryItem) -> Listed? {
        state.withLock { state -> Listed? in
            guard var items = cached(&state) else { return nil }
            if let last = items.last,
               last.query == item.query,
               last.connectionId == item.connectionId,
               last.wasSuccessful == item.wasSuccessful {
                return nil
            }
            items.append(item)
            items = Self.withinBudget(items)
            guard commit(items, to: &state) else { return nil }
            return Listed(items: items.filter { $0.connectionId == item.connectionId }, generation: state.generation)
        }
    }

    func listed(for connectionId: UUID) -> Listed {
        state.withLock { state in
            let items = cached(&state) ?? []
            return Listed(items: items.filter { $0.connectionId == connectionId }, generation: state.generation)
        }
    }

    func loadAll() -> [QueryHistoryItem] {
        state.withLock { cached(&$0) } ?? []
    }

    func load(for connectionId: UUID) -> [QueryHistoryItem] {
        loadAll().filter { $0.connectionId == connectionId }
    }

    var generation: Int {
        state.withLock { $0.generation }
    }

    func delete(_ id: UUID) {
        state.withLock { state in
            guard var items = cached(&state) else { return }
            items.removeAll { $0.id == id }
            commit(items, to: &state)
        }
    }

    // The set-aside copy holds every connection's history: only a clear asked for after the footer named it removes it.
    func clearAll(for connectionIds: Set<UUID>, removingSetAsideCopies: Bool = false) {
        state.withLock { state in
            guard let items = cached(&state) else { return }
            let kept = items.filter { !connectionIds.contains($0.connectionId) }
            if kept.count != items.count {
                guard commit(kept, to: &state) else { return }
            }
            if removingSetAsideCopies {
                removeSetAsideCopies()
            }
        }
    }

    static func withinBudget(_ items: [QueryHistoryItem]) -> [QueryHistoryItem] {
        var kept: [QueryHistoryItem] = []
        var bytes = 0
        for item in items.reversed() {
            let size = item.query.utf8.count + (item.errorMessage?.utf8.count ?? 0)
            guard kept.isEmpty || (kept.count < maxEntries && bytes + size <= maxTextBytes) else { break }
            kept.append(item)
            bytes += size
        }
        return kept.reversed()
    }

    // nil while the file cannot be read (a locked device), so no write replaces it with a partial list.
    private func cached(_ state: inout State) -> [QueryHistoryItem]? {
        if state.items == nil { state.items = readAll() }
        return state.items
    }

    @discardableResult
    private func commit(_ items: [QueryHistoryItem], to state: inout State) -> Bool {
        guard writeAll(items) else { return false }
        state.items = items
        state.generation += 1
        return true
    }

    var hasSetAsideCopies: Bool {
        !setAsideCopies().isEmpty
    }

    private func setAsideCopies() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names
            .filter { $0.hasPrefix("query-history.damaged-") }
            .map { directory.appendingPathComponent($0) }
    }

    private func removeSetAsideCopies() {
        for copy in setAsideCopies() {
            do {
                try FileManager.default.removeItem(at: copy)
            } catch {
                Self.logger.error("A set-aside query history copy could not be deleted: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func readAll() -> [QueryHistoryItem]? {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let items = try? JSONDecoder().decode([QueryHistoryItem].self, from: data) {
            return items
        }
        return setAsideUndecodableFile() ? [] : nil
    }

    private func setAsideUndecodableFile() -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        var attempt = 0
        var destination = directory.appendingPathComponent("query-history.damaged-\(stamp).json")
        while FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            attempt += 1
            destination = directory.appendingPathComponent("query-history.damaged-\(stamp)-\(attempt).json")
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            Self.logger.fault("Query history did not decode and was set aside")
            return true
        } catch {
            Self.logger.error("Query history did not decode and could not be set aside: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    @discardableResult
    private func writeAll(_ items: [QueryHistoryItem]) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])) != nil
    }
}
