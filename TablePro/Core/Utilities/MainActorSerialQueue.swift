import Foundation

@MainActor
internal final class MainActorSerialQueue {
    private var tail: Task<Void, Never>?

    nonisolated internal init() {}

    internal func run<Value: Sendable>(_ operation: @escaping @MainActor () async -> Value) async -> Value {
        let previous = tail
        let current = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { @MainActor in
            _ = await current.value
        }
        return await current.value
    }
}
