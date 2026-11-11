//
//  FakeCNAMEResolver.swift
//  TableProTests
//

import Foundation
import TableProPluginKit

// Answers from a fixed table and records each name asked, so a test never reaches real DNS.
final class FakeCNAMEResolver: CNAMEResolving, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: String]
    private let failing: Set<String>
    private var asked: [String] = []

    init(_ records: [String: String] = [:], failing: Set<String> = []) {
        self.records = records
        self.failing = failing
    }

    var queried: [String] {
        lock.withLock { asked }
    }

    func point(_ name: String, at target: String?) {
        lock.withLock { records[name] = target }
    }

    func cnameTarget(of name: String, within timeout: Duration?) async -> CNAMELookup {
        lock.withLock {
            asked.append(name)
            if failing.contains(name) {
                return .failed
            }
            return records[name].map(CNAMELookup.found) ?? .notFound
        }
    }
}
