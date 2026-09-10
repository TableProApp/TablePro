import Foundation

@MainActor
final class SchemaColumnStore {
    typealias Entry = (columns: [String], primaryKeys: [String])

    /// One fetch shared by every caller asking for the same key while it is in flight.
    ///
    /// `id` is what makes the sharing safe. A waiter's cleanup runs on a deferred hop, so by the
    /// time it lands the key can already belong to a different fetch. Everything that mutates a
    /// load, or writes the result of one, checks the id it started with first.
    private struct Load {
        let id: Int
        let task: Task<Void, Never>
        var liveWaiters: Int
    }

    private var entries: [String: Entry] = [:]
    private var loads: [String: Load] = [:]
    private var lastLoadID = 0

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

        let load = joinLoad(key, fetch: fetch)

        await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.withdrawWaiter(from: key, loadID: load.id) }
        }

        guard loads[key]?.id == load.id else { return }
        loads.removeValue(forKey: key)
    }

    func removeAll() {
        for load in loads.values { load.task.cancel() }
        loads.removeAll()
        entries.removeAll()
    }

    /// A cancelled load is never joined. Between the last waiter leaving and its `load` clearing
    /// the entry there is a window where the task is already cancelled, and a caller that adopted
    /// it would wait for a fetch that is never going to produce anything. Clicking back to a table
    /// just after clicking away from it lands exactly there.
    private func joinLoad(_ key: String, fetch: @escaping () async -> Entry?) -> Load {
        if var existing = loads[key], !existing.task.isCancelled {
            existing.liveWaiters += 1
            loads[key] = existing
            return existing
        }

        lastLoadID += 1
        let id = lastLoadID
        let task = Task { [weak self] in
            guard let entry = await fetch() else { return }
            guard let self, self.loads[key]?.id == id else { return }
            self.entries[key] = entry
        }
        let load = Load(id: id, task: task, liveWaiters: 1)
        loads[key] = load
        return load
    }

    #if DEBUG
    internal func waiterCount(for key: String) -> Int {
        loads[key]?.liveWaiters ?? 0
    }

    internal func loadID(for key: String) -> Int? {
        loads[key]?.id
    }

    internal func withdrawWaiterForTesting(from key: String, loadID: Int) {
        withdrawWaiter(from: key, loadID: loadID)
    }
    #endif

    /// Ignores a withdrawal aimed at a load this key no longer holds. The hop that calls this is
    /// scheduled when a waiter is cancelled and runs later, by which time its load may have
    /// finished and a different caller may own the key. Without the id check that late hop
    /// decrements a stranger's waiter count and cancels a fetch somebody is still waiting on.
    private func withdrawWaiter(from key: String, loadID: Int) {
        guard var load = loads[key], load.id == loadID else { return }
        load.liveWaiters -= 1
        loads[key] = load
        guard load.liveWaiters <= 0 else { return }
        load.task.cancel()
    }
}
