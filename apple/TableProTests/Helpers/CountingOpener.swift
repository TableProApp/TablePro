//
//  CountingOpener.swift
//  TableProTests
//

import Foundation
@testable import TablePro

// Stands in for opening a pooled connection, remembering each driver by the database it was opened for.
@MainActor
final class CountingOpener {
    private let connectDelaySeconds: Double
    private(set) var opened: [MockDatabaseDriver] = []
    private(set) var openedByDatabase: [String: MockDatabaseDriver] = [:]
    private(set) var openOrder: [String] = []
    private(set) var peakOpenCount = 0
    var configure: ((MockDatabaseDriver) -> Void)?
    var afterOpen: ((DatabaseScope) -> Void)?
    var deadOnArrival: Set<String> = []

    init(connectDelaySeconds: Double = 0) {
        self.connectDelaySeconds = connectDelaySeconds
    }

    var openCount: Int {
        opened.filter { $0.disconnectCallCount == 0 }.count
    }

    func open(_ scope: DatabaseScope) async throws -> DatabaseDriver {
        let driver = MockDatabaseDriver()
        driver.connectDelaySeconds = connectDelaySeconds
        driver.hasLostConnection = deadOnArrival.remove(scope.database) != nil
        configure?(driver)
        opened.append(driver)
        openedByDatabase[scope.database] = driver
        openOrder.append(scope.database)
        peakOpenCount = max(peakOpenCount, openCount)
        try await driver.connect()
        afterOpen?(scope)
        return driver
    }
}
