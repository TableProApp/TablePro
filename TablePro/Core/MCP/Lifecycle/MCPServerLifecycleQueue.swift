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

    internal func run(_ work: @escaping @MainActor () async -> Void) async {
        await enqueue(work).value
    }

    internal func drain() async {
        await tail?.value
    }
}
