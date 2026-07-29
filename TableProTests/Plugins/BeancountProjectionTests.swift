//
//  BeancountProjectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Beancount SQL projection")
struct BeancountProjectionTests {
    @Test("projects transactions, postings, and resolved cost basis")
    func projectsTransactionsAndPostings() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let transactions = try await driver.execute(query: "SELECT id, payee, narration FROM transactions ORDER BY id")
        #expect(transactions.rows.map { $0.map(\.asText) } == [
            ["1", "Cafe", "Coffee"],
            ["2", "Broker", "Buy stock"]
        ])

        let postings = try await driver.execute(query: """
            SELECT transaction_id, account, amount, commodity, cost_number, cost_currency
            FROM postings ORDER BY id
            """)
        #expect(postings.rows.map { $0.map(\.asText) } == [
            ["1", "Expenses:Food", "4.00", "USD", nil, nil],
            ["1", "Assets:Cash", "-4.00", "USD", nil, nil],
            ["2", "Assets:Stock", "10", "HOOL", "100.00", "USD"],
            ["2", "Assets:Cash", "-1000.00", "USD", nil, nil]
        ])
    }

    @Test("projects computed balances, assertions, accounts, and prices")
    func projectsBalancesAssertionsAccountsPrices() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let balances = try await driver.execute(query: "SELECT account, amount, commodity FROM balances ORDER BY account")
        #expect(balances.rows.map { $0.map(\.asText) } == [
            ["Assets:Cash", "-1004.00", "USD"],
            ["Assets:Stock", "10", "HOOL"],
            ["Expenses:Food", "4.00", "USD"]
        ])

        let assertions = try await driver.execute(query: "SELECT date, account, amount, commodity FROM balance_assertions")
        #expect(assertions.rows.map { $0.map(\.asText) } == [["2024-01-31", "Assets:Cash", "-1004.00", "USD"]])

        let accounts = try await driver.execute(query: "SELECT name, currencies FROM accounts ORDER BY name")
        #expect(accounts.rows.map { $0.map(\.asText) } == [
            ["Assets:Cash", "USD"],
            ["Assets:Stock", "HOOL"],
            ["Expenses:Food", "USD"]
        ])

        let prices = try await driver.execute(query: "SELECT date, commodity, amount, currency FROM prices")
        #expect(prices.rows.map { $0.map(\.asText) } == [["2024-01-02", "USD", "1.35", "CAD"]])
    }

    @Test("records parsed source files and rejects writes")
    func recordsSourceFilesAndRejectsWrites() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let sources = try await driver.execute(query: "SELECT path FROM source_files")
        #expect(sources.rows.map { $0.first?.asText } == [Self.ledgerURL.path])

        await #expect(throws: BeancountDriverError.self) {
            _ = try await driver.execute(query: "DELETE FROM postings")
        }
    }

    // MARK: - Fixtures

    private static let ledgerURL = URL(fileURLWithPath: "/tmp/tablepro-beancount-fixture/main.beancount")

    private static func makeDriver() throws -> BeancountPluginDriver {
        let handle = try BeancountPluginDriver.loadProjection(rows: cannedRows, sourceFiles: [ledgerURL])
        let driver = BeancountPluginDriver(
            config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: ledgerURL.path)
        )
        driver.installProjection(handle, ledgerURL: ledgerURL)
        return driver
    }

    private static let cannedRows = BeancountProjectionRows(
        transactionsAndPostings: [
            row(id: 1, payee: "Cafe", narration: "Coffee", account: "Expenses:Food", number: "4.00", currency: "USD"),
            row(id: 1, payee: "Cafe", narration: "Coffee", account: "Assets:Cash", number: "-4.00", currency: "USD"),
            row(
                id: 2, payee: "Broker", narration: "Buy stock", account: "Assets:Stock",
                number: "10", currency: "HOOL", costNumber: "100.00", costCurrency: "USD"
            ),
            row(id: 2, payee: "Broker", narration: "Buy stock", account: "Assets:Cash", number: "-1000.00", currency: "USD")
        ],
        accounts: [
            ["account": "Assets:Cash", "open": "2024-01-01", "currencies": ["USD"]],
            ["account": "Assets:Stock", "open": "2024-01-01", "currencies": ["HOOL"]],
            ["account": "Expenses:Food", "open": "2024-01-01", "currencies": ["USD"]]
        ],
        prices: [
            ["date": "2024-01-02", "currency": "USD", "amount": ["number": "1.35", "currency": "CAD"]]
        ],
        balances: [
            position(account: "Assets:Cash", number: "-1004.00", currency: "USD"),
            position(account: "Assets:Stock", number: "10", currency: "HOOL"),
            position(account: "Expenses:Food", number: "4.00", currency: "USD")
        ],
        balanceAssertions: [
            ["date": "2024-01-31", "account": "Assets:Cash", "amount": ["number": "-1004.00", "currency": "USD"]]
        ]
    )

    private static func row(
        id: Int,
        payee: String,
        narration: String,
        account: String,
        number: String,
        currency: String,
        costNumber: String? = nil,
        costCurrency: String? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "date": "2024-01-05", "flag": "*", "payee": payee, "narration": narration,
            "account": account, "number": number, "currency": currency
        ]
        row["cost_number"] = costNumber
        row["cost_currency"] = costCurrency
        return row
    }

    private static func position(account: String, number: String, currency: String) -> [String: Any] {
        ["account": account, "balance": ["positions": [["number": number, "currency": currency]]]]
    }
}
