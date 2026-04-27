//
//  AIProviderRegistry.swift
//  TablePro
//
//  Thread-safe registry of all known AI provider descriptors.
//

import Foundation
import os

/// Singleton registry of AI provider descriptors
final class AIProviderRegistry: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AIProviderRegistry")

    static let shared = AIProviderRegistry()

    private let lock = OSAllocatedUnfairLock(initialState: [String: AIProviderDescriptor]())

    private init() {}

    func register(_ descriptor: AIProviderDescriptor) {
        lock.withLock { $0[descriptor.typeID] = descriptor }
        Self.logger.debug("Registered AI provider: \(descriptor.typeID)")
    }

    func descriptor(for typeID: String) -> AIProviderDescriptor? {
        lock.withLock { $0[typeID] }
    }

    var allDescriptors: [AIProviderDescriptor] {
        lock.withLock { Array($0.values) }
    }
}
