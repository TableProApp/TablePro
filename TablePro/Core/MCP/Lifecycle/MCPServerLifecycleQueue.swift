import Foundation

@MainActor
internal final class MCPServerLifecycleQueue {
    private var tail: Task<Void, Never>?

    internal init() {}

    @discardableResult
    internal func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        tail = task
        return task
    }

    @discardableResult
    internal func run<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) async -> Value {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return await task.value
    }

    internal func drain() async {
        await tail?.value
    }
}
