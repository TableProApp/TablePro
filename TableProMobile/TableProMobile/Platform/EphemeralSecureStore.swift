import Foundation
import os
import TableProDatabase

nonisolated final class EphemeralSecureStore: SecureStore {
    private let values: OSAllocatedUnfairLock<[String: String]>

    init(_ values: [String: String] = [:]) {
        self.values = OSAllocatedUnfairLock(initialState: values)
    }

    func store(_ value: String, forKey key: String) throws {
        values.withLock { $0[key] = value }
    }

    func retrieve(forKey key: String) throws -> String? {
        values.withLock { $0[key] }
    }

    func delete(forKey key: String) throws {
        values.withLock { $0[key] = nil }
    }
}
