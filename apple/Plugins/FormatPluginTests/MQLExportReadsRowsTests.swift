//
//  MQLExportReadsRowsTests.swift
//  FormatPluginTests
//

import TableProPluginKit
import Testing

struct MQLExportReadsRowsTests {
    @Test("An MQL export reads a collection's documents only with Data checked")
    func readsRowsOnlyWithData() {
        let plugin = MQLExportPlugin()
        #expect(plugin.readsRows(optionValues: [true, true, true], kind: .table))
        #expect(!plugin.readsRows(optionValues: [true, true, false], kind: .table))
        #expect(plugin.readsRows(optionValues: [], kind: .table))
    }
}
