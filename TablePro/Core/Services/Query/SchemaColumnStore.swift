import Foundation

@MainActor
final class SchemaColumnStore {
    typealias Entry = (columns: [String], primaryKeys: [String])

    /// One fetch shared by every caller asking for the same key while it is in flight. It is only
    /// cancelled once the last of them has given up, because cancelling on the first departure
    /// would abandon a fetch the others are still waiting on.
    private struct Load {
        let task: Task<Void, Never>
        var liveWaiters: Int
    }

    private var entries: [String: Entry] = [:]
    private var loads: [String: Load] = [:]
    private var generation = 0

    func cached(_ key: String) -> Entry? {
        entries[key]
    }

    func store(_ entry: Entry, for key: String) {
        entries[key] = entry
    }

    /// Carries the caller's cancellation into the fetch. The shared task is unstructured, so it
    /// inherits nothing from whoever awaits it: without this, a navigation the user has already
    /// clicked past still runs its metadata query to the end, holding the serial metadata
    /// connection while every table behind it waits.
    ///
    /// A cancelled caller that is not the last one waiting stays suspended until the fetch its
    /// peers still want has finished. That costs nothing, because it discards the result as soon
    /// as it resumes, and the alternative is taking the fetch away from a caller that needs it.
    func load(_ key: String, fetch: @escaping () async -> Entry?) async {
        if entries[key] != nil { return }

        let task = joinLoad(key, fetch: fetch)
        let startedGeneration = generation

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdrawWaiter(from: key) }
        }

        guard generation == startedGeneration else { return }
        loads.removeValue(forKey: key)
    }

    func removeAll() {
        generation += 1
        for load in loads.values { load.task.cancel() }
        loads.removeAll()
        entries.removeAll()
    }

    /// A cancelled load is never joined. Between the last waiter leaving and its `load` clearing
    /// the entry there is a window where the task is already cancelled, and a caller that adopted
    /// it would wait for a fetch that is never going to produce anything. Clicking back to a table
    /// just after clicking away from it lands exactly there.
    private func joinLoad(_ key: String, fetch: @escaping () async -> Entry?) -> Task<Void, Never> {
        if var existing = loads[key], !existing.task.isCancelled {
            existing.liveWaiters += 1
            loads[key] = existing
            return existing.task
        }

        let task = Task { [weak self] in
            guard let entry = await fetch() else { return }
            self?.entries[key] = entry
        }
        loads[key] = Load(task: task, liveWaiters: 1)
        return task
    }

    #if DEBUG
    internal func waiterCount(for key: String) -> Int {
        loads[key]?.liveWaiters ?? 0
    }
    #endif

    private func withdrawWaiter(from key: String) {
        guard var load = loads[key] else { return }
        load.liveWaiters -= 1
        loads[key] = load
        guard load.liveWaiters <= 0 else { return }
        load.task.cancel()
    }
}
