import Foundation

@MainActor
final class SchemaColumnStore {
    typealias Entry = (columns: [String], primaryKeys: [String])

    private var entries: [String: Entry] = [:]
    private var loads: [String: Task<Void, Never>] = [:]
    private var generation = 0

    func cached(_ key: String) -> Entry? {
        entries[key]
    }

    func store(_ entry: Entry, for key: String) {
        entries[key] = entry
    }

    func load(_ key: String, fetch: @escaping () async -> Entry?) async {
        if entries[key] != nil { return }
        if let inFlight = loads[key] {
            await inFlight.value
            return
        }

        let task = Task {
            if let entry = await fetch() {
                self.entries[key] = entry
            }
        }
        loads[key] = task
        let startedGeneration = generation
        await task.value
        if generation == startedGeneration {
            loads[key] = nil
        }
    }

    func removeAll() {
        generation += 1
        for task in loads.values { task.cancel() }
        loads.removeAll()
        entries.removeAll()
    }
}
