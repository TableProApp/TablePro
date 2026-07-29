//
//  ExportServiceTimeoutTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
@Suite("ExportService Statement Timeout")
struct ExportServiceTimeoutTests {
    private func makeService(driver: MockDatabaseDriver) -> ExportService {
        ExportService(driver: driver, databaseType: .mysql)
    }

    @Test("suppressStatementTimeout disables the timeout on the driver")
    func suppressSendsZero() async {
        let driver = MockDatabaseDriver()
        let service = makeService(driver: driver)
        await service.suppressStatementTimeout(on: driver)
        #expect(driver.applyQueryTimeoutValues == [0])
    }

    @Test("restoreStatementTimeout re-applies the configured timeout")
    func restoreSendsConfiguredTimeout() async {
        let driver = MockDatabaseDriver()
        let service = makeService(driver: driver)
        await service.restoreStatementTimeout(on: driver)
        let configured = AppSettingsManager.shared.general.queryTimeoutSeconds
        #expect(driver.applyQueryTimeoutValues == [configured])
    }

    @Test("Suppress then restore sends disable followed by the configured timeout")
    func suppressThenRestore() async {
        let driver = MockDatabaseDriver()
        let service = makeService(driver: driver)
        await service.suppressStatementTimeout(on: driver)
        await service.restoreStatementTimeout(on: driver)
        let configured = AppSettingsManager.shared.general.queryTimeoutSeconds
        #expect(driver.applyQueryTimeoutValues == [0, configured])
    }
}
