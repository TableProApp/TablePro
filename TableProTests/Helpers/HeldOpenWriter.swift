//
//  HeldOpenWriter.swift
//  TableProTests
//

import Foundation

internal struct HeldOpenWriter: Sendable {
    private enum Arrival<Value: Sendable>: Sendable {
        case finished(Value)
        case deadlinePassed
    }

    private static let deadline = Duration.seconds(10)

    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func finished<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value? {
        let handle = handle
        return await withTaskGroup(of: Arrival<Value>.self) { group in
            group.addTask { .finished(await work()) }
            group.addTask {
                try? await Task.sleep(for: Self.deadline)
                return .deadlinePassed
            }
            guard case .finished(let value)? = await group.next() else {
                try? handle.close()
                return nil
            }
            group.cancelAll()
            return value
        }
    }

    func finishedOnItsOwnThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value? {
        await finished {
            await withCheckedContinuation { continuation in
                Thread.detachNewThread { continuation.resume(returning: work()) }
            }
        }
    }
}
