//
//  BeancountRledgerOutputTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

extension BeancountPluginDriverTests {
    @Test("reads rledger rows written as objects and as positional arrays")
    func readsBothRledgerRowShapes() throws {
        let position = #"{"cost": null, "units": {"currency": "USD", "number": "19.43"}}"#
        let keyed = Data(#"{"columns": ["account", "position"], "rows": [{"account": "Expenses:Food", "position": \#(position)}]}"#.utf8)
        let positional = Data(#"{"columns": ["account", "position"], "rows": [["Expenses:Food", \#(position)]]}"#.utf8)

        for data in [keyed, positional] {
            let result = try BeancountPluginDriver.decodeRustledgerQueryOutput(data, executionTime: 0)
            #expect(result.columns == ["account", "position"])
            #expect(result.rows.map { $0.map(\.asText) } == [["Expenses:Food", "19.43 USD"]])

            let rows = try BeancountPluginDriver.decodeRledgerRows(data)
            #expect(rows.map { $0["account"] as? String } == ["Expenses:Food"])
        }
    }

    @Test("keeps two BQL columns that share a name apart")
    func keepsBQLColumnsSharingANameApart() throws {
        let data = Data(#"{"columns": ["a", "a"], "rows": [["2024-01-05", "Assets:Cash"]]}"#.utf8)
        let result = try BeancountPluginDriver.decodeRustledgerQueryOutput(data, executionTime: 0)
        #expect(result.rows.map { $0.map(\.asText) } == [["2024-01-05", "Assets:Cash"]])
    }

    @Test("fails on rledger rows of an unknown shape instead of reading them as no rows")
    func rejectsUnknownRledgerRowShape() {
        let data = Data(#"{"columns": ["account"], "rows": ["Assets:Cash"]}"#.utf8)
        #expect(throws: BeancountDriverError.self) {
            _ = try BeancountPluginDriver.decodeRustledgerQueryOutput(data, executionTime: 0)
        }
        #expect(throws: BeancountDriverError.self) {
            _ = try BeancountPluginDriver.decodeRledgerRows(data)
        }
    }

    @Test("renders rledger values the way rledger prints them")
    func rendersRledgerValues() throws {
        let cases: [(json: String, text: String)] = [
            (#"{"cost": null, "units": {"currency": "USD", "number": "19.43"}}"#, "19.43 USD"),
            (
                #"{"cost": {"currency": "USD", "number": "150.00"}, "units": {"currency": "AAPL", "number": "2"}}"#,
                "2 AAPL {150.00 USD}"
            ),
            (#"{"positions": [{"currency": "AAPL", "number": "3"}, {"currency": "USD", "number": "-451.00"}]}"#, "3 AAPL, -451.00 USD"),
            (#"{"positions": []}"#, ""),
            (#"["trip", "food"]"#, "trip, food"),
            (#"{"count": 1, "unit": "month"}"#, "1 month"),
            (#"{"count": 3, "unit": "day"}"#, "3 days"),
            (#"{"count": -1, "unit": "week"}"#, "-1 week"),
            (#"{"count": -9223372036854775808, "unit": "day"}"#, "-9223372036854775808 days"),
            ("true", "TRUE"),
            ("false", "FALSE"),
            ("12", "12"),
            (#"{"key": "value"}"#, #"{"key":"value"}"#)
        ]
        for testCase in cases {
            let value = try JSONSerialization.jsonObject(with: Data(testCase.json.utf8), options: .fragmentsAllowed)
            #expect(BeancountPluginDriver.rustledgerCellValue(value) == testCase.text, "\(testCase.json)")
        }
    }

    @Test("keeps a directive's own metadata out of the meta column newer rledger releases return")
    func keepsDirectiveOwnMetadataFromMetaColumn() throws {
        let meta: [String: Any] = [
            "filename": "/ledger/main.beancount",
            "lineno": 3,
            "__tolerances__": ["USD": "0.005"],
            "name": "US Dollar"
        ]
        let own = try #require(BeancountPluginDriver.ownMetadata(meta) as? [String: Any])
        #expect(own.keys.sorted() == ["name"])
        #expect(own["name"] as? String == "US Dollar")
        #expect(BeancountPluginDriver.ownMetadata(["filename": "/ledger/main.beancount", "lineno": 3]) is NSNull)
        #expect(BeancountPluginDriver.ownMetadata(nil) is NSNull)
    }

    @Test(
        "shows BQL positions as units and cost, and one balance per commodity held in lots",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func showsPositionsAndLotBalancesThroughRustledger() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Broker AAPL
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Expenses:Food USD

            2024-01-03 * "Cafe" "Lunch" #trip
              Expenses:Food  19.43 USD
              Assets:Cash

            2024-01-04 * "Broker" "Buy"
              Assets:Broker  2 AAPL {150.00 USD}
              Assets:Cash

            2024-01-05 * "Broker" "Buy"
              Assets:Broker  1 AAPL {151.00 USD}
              Assets:Cash
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let positions = try await driver.execute(query: """
                BQL: SELECT date, account, position, tags WHERE account != 'Assets:Cash' ORDER BY date
                """)
            #expect(positions.rows.map { $0.map(\.asText) } == [
                ["2024-01-03", "Expenses:Food", "19.43 USD", "trip"],
                ["2024-01-04", "Assets:Broker", "2 AAPL {150.00 USD}", ""],
                ["2024-01-05", "Assets:Broker", "1 AAPL {151.00 USD}", ""]
            ])

            let balances = try await driver.execute(query: """
                SELECT account, amount, commodity FROM balances ORDER BY account, commodity
                """)
            #expect(balances.rows.map { $0.map(\.asText) } == [
                ["Assets:Broker", "3", "AAPL"],
                ["Assets:Cash", "-470.43", "USD"],
                ["Expenses:Food", "19.43", "USD"]
            ])
        }
    }

    @Test(
        "keeps directive metadata when the first ledger opened has no transactions",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func keepsDirectiveMetadataAfterLedgerWithoutTransactions() async throws {
        let rledger = try #require(RustledgerLocator.path)
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A fresh executable path, so no earlier test has already chosen the metadata column for it.
        let wrapper = directory.appendingPathComponent("rledger")
        try "#!/bin/sh\nexec \"\(rledger)\" \"$@\"\n".write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let accountsOnly = directory.appendingPathComponent("accounts.beancount")
        try "2024-01-01 open Assets:Cash USD\n".write(to: accountsOnly, atomically: true, encoding: .utf8)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 commodity USD
          name: "US Dollar"

        2024-01-07 * "Archive" "No postings" #empty ^standalone
          reason: "record only"
        """.write(to: ledger, atomically: true, encoding: .utf8)

        try await Self.withRustledgerEnvironment(wrapper.path) {
            let first = BeancountPluginDriver(config: Self.config(accountsOnly))
            try await first.connect()
            first.disconnect()

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let transactionMetadata = try await driver.execute(query: """
                SELECT key, value FROM transaction_metadata ORDER BY key
                """)
            #expect(transactionMetadata.rows.map { $0.map(\.asText) } == [["reason", "record only"]])

            let tags = try await driver.execute(query: "SELECT tag FROM transaction_tags")
            #expect(tags.rows.map { $0[0].asText } == ["empty"])

            let directiveMetadata = try await driver.execute(query: """
                SELECT d.type, m.key, m.value FROM directive_metadata m
                JOIN directives d ON d.id = m.directive_id
                """)
            #expect(directiveMetadata.rows.map { $0.map(\.asText) } == [["commodity", "name", "US Dollar"]])
        }
    }
}
