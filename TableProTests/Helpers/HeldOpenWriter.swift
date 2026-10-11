//
//  HeldOpenWriter.swift
//  TableProTests
//

import Foundation

internal struct HeldOpenWriter: Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func finished<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) async -> Value? {
        await BoundedCall.result(onDeadline: closeWriter, of: work)
    }

    func finishedOnItsOwnThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value? {
        await BoundedCall.resultOnItsOwnThread(onDeadline: closeWriter, of: work)
    }

    private var closeWriter: @Sendable () -> Void {
        let handle = handle
        return { try? handle.close() }
    }
}
