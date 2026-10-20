import Foundation

// The query editor's text per connection: saved after a pause in typing, and at once when the editor goes away.
@MainActor
final class QueryDraftSaver {
    private static let pause: Duration = .milliseconds(300)

    private let defaults: UserDefaults
    private var pending: (connectionId: UUID, text: String)?
    private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restore(for connectionId: UUID) -> String? {
        defaults.string(forKey: ConnectionDefaultsKey.lastQuery.name(for: connectionId))
    }

    func textChanged(_ text: String, for connectionId: UUID) {
        pending = (connectionId, text)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let pending else { return }
        self.pending = nil
        defaults.set(pending.text, forKey: ConnectionDefaultsKey.lastQuery.name(for: pending.connectionId))
    }
}
