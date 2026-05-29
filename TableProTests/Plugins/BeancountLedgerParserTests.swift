//
//  BeancountLedgerParserTests.swift
//  TableProTests
//

import Foundation
import Testing

@Suite("Beancount ledger parser")
struct BeancountLedgerParserTests {
    @Test("loads transactions, postings, accounts, prices, balances, and includes")
    func parsesCoreTablesAndIncludes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let included = tempDirectory.appendingPathComponent("prices.beancount")
        try """
        2024-01-02 price USD 1.35 CAD
        2024-01-31 balance Assets:Bank:Checking 900.00 USD
        """.write(to: included, atomically: true, encoding: .utf8)

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        option "title" "Household"
        include "prices.beancount"

        2024-01-01 open Assets:Bank:Checking USD
        2024-01-01 open Expenses:Food USD

        2024-01-15 * "Grocery Store" "Weekly shop"
          Assets:Bank:Checking  -100.00 USD
          Expenses:Food          100.00 USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let parsed = try BeancountLedgerParser().parse(fileURL: ledger)

        #expect(parsed.accounts.map(\.name).sorted() == ["Assets:Bank:Checking", "Expenses:Food"])
        #expect(parsed.transactions.map(\.payee) == ["Grocery Store"])
        #expect(parsed.transactions.map(\.narration) == ["Weekly shop"])
        #expect(parsed.postings.count == 2)
        #expect(parsed.prices.first?.commodity == "USD")
        #expect(parsed.prices.first?.currency == "CAD")
        #expect(parsed.balances.first?.account == "Assets:Bank:Checking")
        #expect(parsed.sourceFiles.map(\.lastPathComponent).sorted() == ["main.beancount", "prices.beancount"])
    }

    @Test("expands glob include paths")
    func parsesGlobIncludes() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-parser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let imports = tempDirectory.appendingPathComponent("imports", isDirectory: true)
        let nested = imports.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try """
        2024-01-01 open Assets:Bank:Checking USD
        """.write(to: imports.appendingPathComponent("accounts.beancount"), atomically: true, encoding: .utf8)

        try """
        2024-01-01 open Expenses:Food USD
        """.write(to: nested.appendingPathComponent("expenses.beancount"), atomically: true, encoding: .utf8)

        let ledger = tempDirectory.appendingPathComponent("main.beancount")
        try """
        include "imports/*.beancount"
        include "imports/**/*.beancount"

        2024-01-15 * "Grocery Store" "Weekly shop"
          Assets:Bank:Checking  -100.00 USD
          Expenses:Food          100.00 USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let parsed = try BeancountLedgerParser().parse(fileURL: ledger)

        #expect(parsed.accounts.map(\.name).sorted() == ["Assets:Bank:Checking", "Expenses:Food"])
        #expect(parsed.transactions.count == 1)
        #expect(parsed.sourceFiles.map(\.lastPathComponent).sorted() == [
            "accounts.beancount",
            "expenses.beancount",
            "main.beancount"
        ])
    }
}
