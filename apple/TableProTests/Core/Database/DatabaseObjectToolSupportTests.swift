//
//  DatabaseObjectToolSupportTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class CountingTypeDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0

    var probeCount: Int {
        lock.withLock { probes }
    }

    func generateDropTypeSQL(type: PluginUserDefinedTypeInfo) -> String? {
        lock.withLock { probes += 1 }
        return "DROP TYPE \(type.name)"
    }
}

@MainActor
struct DatabaseObjectToolSupportTests {
    @Test("A driver is probed once, however often its support is asked for")
    func probesEachDriverOnce() {
        let connection = TestFixtures.makeConnection(database: "shop", type: .cassandra)
        let plugin = CountingTypeDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: plugin)

        let first = DatabaseObjectToolEligibility.Support.of(adapter)
        let probesForOneAnswer = plugin.probeCount
        let second = DatabaseObjectToolEligibility.Support.of(adapter)

        #expect(probesForOneAnswer > 0)
        #expect(plugin.probeCount == probesForOneAnswer)
        #expect(second == first)
        #expect(!first.droppableTypeKinds.isEmpty)
    }

    @Test("A new driver for the same connection is probed again")
    func newDriverIsProbed() {
        let connection = TestFixtures.makeConnection(database: "shop", type: .cassandra)
        let plugin = CountingTypeDriver()

        _ = DatabaseObjectToolEligibility.Support.of(PluginDriverAdapter(connection: connection, pluginDriver: plugin))
        let afterFirstDriver = plugin.probeCount
        _ = DatabaseObjectToolEligibility.Support.of(PluginDriverAdapter(connection: connection, pluginDriver: plugin))

        #expect(plugin.probeCount == afterFirstDriver * 2)
    }
}
