import Foundation

public final class PluginQueryCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastGeneration = 0
    private var activeGeneration: Int?
    private var cancelledGeneration: Int?

    public init() {}

    public func beginQuery() -> Int {
        lock.lock()
        defer { lock.unlock() }
        lastGeneration += 1
        activeGeneration = lastGeneration
        return lastGeneration
    }

    public func endQuery(_ generation: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard activeGeneration == generation else { return }
        activeGeneration = nil
    }

    @discardableResult
    public func cancel() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let generation = activeGeneration else { return nil }
        cancelledGeneration = generation
        return generation
    }

    public func isCancelled(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledGeneration == generation
    }
}
