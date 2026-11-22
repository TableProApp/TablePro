import Combine
import Foundation

// One settings category per object, so a write re-renders only the views that read that category.
@MainActor
final class SettingsSlice<Value: Codable & Equatable & Sendable>: ObservableObject {
    @Published private var stored: Value
    private let normalize: (Value) -> Value
    private var onCommit: (@MainActor (_ old: Value, _ new: Value) -> Void)?

    init(_ initial: Value, normalize: @escaping (Value) -> Value = { $0 }) {
        stored = initial
        self.normalize = normalize
    }

    var value: Value {
        get { stored }
        set { assign(newValue) }
    }

    var publisher: Published<Value>.Publisher { $stored }

    func update(_ body: (inout Value) -> Void) {
        var next = stored
        body(&next)
        assign(next)
    }

    // Attached after init, so loading a value never saves it or marks it for sync.
    func attach(_ onCommit: @escaping @MainActor (_ old: Value, _ new: Value) -> Void) {
        self.onCommit = onCommit
    }

    private func assign(_ newValue: Value) {
        let candidate = normalize(newValue)
        guard candidate != stored else { return }
        let old = stored
        stored = candidate
        onCommit?(old, candidate)
    }
}
