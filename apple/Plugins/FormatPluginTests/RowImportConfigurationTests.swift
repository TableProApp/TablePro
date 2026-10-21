//
//  RowImportConfigurationTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

/// A run of several files has one transaction, so it reads each format's error handling and transaction options
/// before it starts, and they have to be the ones the format's own import runs with.
struct RowImportConfigurationTests {
    @Test("CSV reports the options its import runs with")
    func csvReportsItsOptions() throws {
        let plugin = CSVImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        plugin.settings.errorHandling = .stopAndCommit
        plugin.settings.wrapInTransaction = false
        plugin.settings.deleteExistingRows = true

        let configuration = try #require(plugin.rowImportConfiguration)

        #expect(configuration.errorHandling == .stopAndCommit)
        #expect(configuration.wrapInTransaction == false)
        #expect(configuration.deleteExistingRows == true)
    }

    @Test("JSON reports the options its import runs with")
    func jsonReportsItsOptions() throws {
        let plugin = JSONImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        plugin.settings.errorHandling = .skipAndContinue

        let configuration = try #require(plugin.rowImportConfiguration)

        #expect(configuration.errorHandling == .skipAndContinue)
        #expect(configuration.wrapInTransaction == saved.wrapInTransaction)
    }

    @Test("XLSX reports the options its import runs with")
    func xlsxReportsItsOptions() throws {
        let plugin = XLSXImportPlugin()
        let saved = plugin.settings
        defer { plugin.settings = saved }
        plugin.settings.deleteExistingRows = true

        let configuration = try #require(plugin.rowImportConfiguration)

        #expect(configuration.deleteExistingRows == true)
        #expect(configuration.errorHandling == saved.errorHandling)
    }
}
