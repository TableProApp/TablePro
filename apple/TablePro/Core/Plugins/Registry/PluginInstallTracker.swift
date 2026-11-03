import Combine
import Foundation

@MainActor
final class PluginInstallTracker: ObservableObject {
    static let shared = PluginInstallTracker()

    enum Trigger: Equatable, Sendable {
        case user
        case repair
        case update
    }

    enum Retry: Sendable {
        case registry(RegistryPlugin)
        case file(URL)
    }

    enum Phase: Equatable, Sendable {
        case downloading(fraction: Double?)
        case installing
        case completed
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .downloading, .installing: true
            case .completed, .failed: false
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let pluginId: String
        let displayName: String
        let generation: UUID
        let order: Int
        let trigger: Trigger
        let retry: Retry?
        var phase: Phase

        var id: String { pluginId }
    }

    struct Ticket: Sendable {
        let pluginId: String
        let generation: UUID
        fileprivate let tracker: PluginInstallTracker

        var reportProgress: @Sendable (Double) async -> Void {
            { [tracker, pluginId, generation] fraction in
                await tracker.reportProgress(pluginId: pluginId, generation: generation, fraction: fraction)
            }
        }

        @MainActor
        func markInstalling() {
            tracker.markInstalling(pluginId: pluginId, generation: generation)
        }
    }

    private struct Handle {
        let cancel: @Sendable () -> Void
        let completion: Task<Void, any Error>
    }

    nonisolated static let completedLifetime: Duration = .seconds(3)

    @Published private(set) var entries: [String: Entry] = [:]

    private var handles: [UUID: Handle] = [:]
    private var nextOrder = 0
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    var isInstalling: Bool {
        entries.values.contains { $0.phase.isRunning }
    }

    var runningEntries: [Entry] {
        entries.values.filter { $0.phase.isRunning }.sorted { $0.order < $1.order }
    }

    var failedEntries: [Entry] {
        entries.values.filter { if case .failed = $0.phase { true } else { false } }.sorted { $0.order < $1.order }
    }

    // The body runs in a task of its own, so any surface can cancel it through the entry.
    func track<T: Sendable>(
        pluginId: String,
        displayName: String,
        trigger: Trigger,
        retry: Retry?,
        startPhase: Phase = .downloading(fraction: nil),
        _ body: @escaping @MainActor @Sendable (Ticket) async throws -> T
    ) async throws -> T {
        guard entries[pluginId]?.phase.isRunning != true else {
            throw PluginError.installFailed(String(localized: "Another install is already in progress for this plugin"))
        }
        let generation = UUID()
        nextOrder += 1
        entries[pluginId] = Entry(
            pluginId: pluginId,
            displayName: displayName,
            generation: generation,
            order: nextOrder,
            trigger: trigger,
            retry: retry,
            phase: startPhase
        )
        let ticket = Ticket(pluginId: pluginId, generation: generation, tracker: self)
        let task = Task { @MainActor in try await body(ticket) }
        let completion = Task<Void, any Error> {
            do {
                _ = try await task.value
            } catch {
                guard !task.isCancelled, !Self.isCancellation(error) else { throw CancellationError() }
                throw error
            }
        }
        handles[generation] = Handle(cancel: { task.cancel() }, completion: completion)
        defer { handles[generation] = nil }

        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            complete(pluginId: pluginId, generation: generation)
            return value
        } catch {
            if task.isCancelled || Self.isCancellation(error) {
                removeEntry(pluginId: pluginId, generation: generation)
                throw CancellationError()
            }
            if entries[pluginId]?.generation == generation {
                entries[pluginId]?.phase = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    // A running install is cancelled; a finished one is dismissed.
    func cancel(pluginId: String) {
        guard let entry = entries[pluginId] else { return }
        guard entry.phase.isRunning else {
            entries[pluginId] = nil
            return
        }
        handles[entry.generation]?.cancel()
    }

    // Returns false when no install of the plugin is running; otherwise waits for it and throws what it threw.
    func joinRunningInstall(of pluginId: String) async throws -> Bool {
        guard let entry = entries[pluginId], entry.phase.isRunning,
              let handle = handles[entry.generation] else { return false }
        try await handle.completion.value
        return true
    }

    func removeCompleted(pluginId: String, generation: UUID) {
        guard let entry = entries[pluginId], entry.generation == generation, entry.phase == .completed else { return }
        entries[pluginId] = nil
    }

    private func complete(pluginId: String, generation: UUID) {
        guard entries[pluginId]?.generation == generation else { return }
        entries[pluginId]?.phase = .completed
        let clock = clock
        Task { [weak self] in
            try? await clock.sleep(for: Self.completedLifetime)
            self?.removeCompleted(pluginId: pluginId, generation: generation)
        }
    }

    private func removeEntry(pluginId: String, generation: UUID) {
        guard entries[pluginId]?.generation == generation else { return }
        entries[pluginId] = nil
    }

    fileprivate func reportProgress(pluginId: String, generation: UUID, fraction: Double) {
        guard fraction < 1 else {
            markInstalling(pluginId: pluginId, generation: generation)
            return
        }
        guard let entry = entries[pluginId], entry.generation == generation,
              case .downloading = entry.phase else { return }
        entries[pluginId]?.phase = .downloading(fraction: max(fraction, 0))
    }

    fileprivate func markInstalling(pluginId: String, generation: UUID) {
        guard let entry = entries[pluginId], entry.generation == generation, entry.phase.isRunning else { return }
        entries[pluginId]?.phase = .installing
    }

    nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
