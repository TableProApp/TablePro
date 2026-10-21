//
//  SQLExportReadsRowsTests.swift
//  FormatPluginTests
//

import TableProPluginKit
import Testing

struct SQLExportReadsRowsTests {
    @Test("A SQL export reads a table's rows only with Data checked, and never a view's")
    func readsRowsOnlyWithData() {
        let plugin = SQLExportPlugin()
        #expect(plugin.readsRows(optionValues: [true, true, true], kind: .table))
        #expect(!plugin.readsRows(optionValues: [true, true, false], kind: .table))
        #expect(!plugin.readsRows(optionValues: [true, true, true], kind: .view))
        #expect(plugin.readsRows(optionValues: [], kind: .table))
    }
}
