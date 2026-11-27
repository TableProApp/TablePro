import Foundation
import os

// Built by its store on the main actor, which knows the item's scope, and run off it: SecItemCopyMatching blocks
// the calling thread.
struct DeferredSecretRead: Sendable {
    let key: String
    private let label: String
    private let logger: Logger
    private let perform: @Sendable () -> KeychainStringResult

    init(key: String, label: String, logger: Logger, perform: @escaping @Sendable () -> KeychainStringResult) {
        self.key = key
        self.label = label
        self.logger = logger
        self.perform = perform
    }

    // Values found, by Keychain key. A read that failed is logged under its label, as the synchronous load logs it.
    @concurrent
    static func run(_ reads: [DeferredSecretRead]) async -> [String: String] {
        var values: [String: String] = [:]
        for read in reads {
            if let value = read.perform().value(label: read.label, logger: read.logger) {
                values[read.key] = value
            }
        }
        return values
    }
}
