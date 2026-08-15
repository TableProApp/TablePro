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

    @Test("projects commodity, document, note, event, and close directives")
    func projectsRichDirectives() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let commodities = try await driver.execute(query: "SELECT date, commodity FROM commodities ORDER BY commodity")
        #expect(commodities.rows.map { $0.map(\.asText) } == [
            ["2024-01-01", "HOOL"],
            ["2024-01-01", "USD"]
        ])

        let documents = try await driver.execute(query: "SELECT date, account, path, tags, links FROM documents")
        #expect(documents.rows.map { $0.map(\.asText) } == [
            ["2024-01-03", "Assets:Cash", "/receipts/jan.pdf", "scanned", "batch-1"]
        ])

        let notes = try await driver.execute(query: "SELECT date, account, comment FROM notes")
        #expect(notes.rows.map { $0.map(\.asText) } == [["2024-01-04", "Assets:Cash", "called the bank"]])

        let events = try await driver.execute(query: "SELECT date, type, description FROM events")
        #expect(events.rows.map { $0.map(\.asText) } == [["2024-01-01", "location", "Taipei"]])

        let closes = try await driver.execute(query: "SELECT date, account FROM closes")
        #expect(closes.rows.map { $0.map(\.asText) } == [["2024-06-30", "Expenses:Food"]])
    }

    @Test("projects transaction metadata, posting metadata, tags, and links")
    func projectsMetadataTagsAndLinks() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let metadata = try await driver.execute(query: """
            SELECT transaction_id, key, value FROM transaction_metadata ORDER BY id
            """)
        #expect(metadata.rows.map { $0.map(\.asText) } == [
            ["1", "invoice", "INV-9"],
            ["1", "reviewed", "TRUE"]
        ])

        let postingMetadata = try await driver.execute(query: """
            SELECT posting_id, key, value FROM posting_metadata ORDER BY id
            """)
        #expect(postingMetadata.rows.map { $0.map(\.asText) } == [["1", "method", "card"]])

        let tags = try await driver.execute(query: "SELECT transaction_id, tag FROM transaction_tags ORDER BY id")
        #expect(tags.rows.map { $0.map(\.asText) } == [["1", "coffee"], ["1", "daily"]])

        let links = try await driver.execute(query: "SELECT transaction_id, link FROM transaction_links ORDER BY id")
        #expect(links.rows.map { $0.map(\.asText) } == [["1", "receipt-123"]])
    }

    @Test("projects source locations for transactions and postings")
    func projectsSourceLocations() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let transactions = try await driver.execute(query: """
            SELECT id, source_file, line, source_location FROM transactions ORDER BY id
            """)
        #expect(transactions.rows.map { $0.map(\.asText) } == [
            ["1", "/ledger/main.beancount", "10", "/ledger/main.beancount:10"],
            ["2", nil, nil, nil]
        ])

        let postings = try await driver.execute(query: """
            SELECT id, source_location FROM postings ORDER BY id LIMIT 2
            """)
        #expect(postings.rows.map { $0.map(\.asText) } == [
            ["1", "/ledger/main.beancount:11"],
            ["2", "/ledger/main.beancount:12"]
        ])
    }

    @Test("projects validation diagnostics and stays empty without a validator")
    func projectsDiagnostics() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let diagnostics = try await driver.execute(query: """
            SELECT source_file, line, source_location, column_number, end_line, end_column,
                   severity, phase, code, message
            FROM diagnostics ORDER BY id
            """)
        #expect(diagnostics.rows.map { $0.map(\.asText) } == [
            [
                "/ledger/main.beancount", "20", "/ledger/main.beancount:20", "1", "22", "1",
                "error", "validate", "E8001", "Document file not found: /receipts/jan.pdf"
            ]
        ])

        let handle = try BeancountPluginDriver.loadProjection(
            rows: BeancountProjectionRows(),
            sourceFiles: [Self.ledgerURL]
        )
        let empty = BeancountPluginDriver(
            config: DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: Self.ledgerURL.path)
        )
        empty.installProjection(handle, ledgerURL: Self.ledgerURL)
        defer { empty.disconnect() }

        let none = try await empty.execute(query: "SELECT COUNT(*) FROM diagnostics")
        #expect(none.rows.first?.first?.asText == "0")
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
            row(
                id: 1, payee: "Cafe", narration: "Coffee", account: "Expenses:Food", number: "4.00", currency: "USD",
                line: 11, entryMeta: ["invoice": "INV-9", "reviewed": true], postingMeta: ["method": "card"],
                tags: ["coffee", "daily"], links: ["receipt-123"]
            ),
            row(
                id: 1, payee: "Cafe", narration: "Coffee", account: "Assets:Cash", number: "-4.00", currency: "USD",
                line: 12, entryMeta: ["invoice": "INV-9", "reviewed": true],
                tags: ["coffee", "daily"], links: ["receipt-123"]
            ),
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
        ],
        transactionLocations: [
            ["id": 1, "filename": "/ledger/main.beancount", "lineno": 10, "location": "/ledger/main.beancount:10"]
        ],
        commodities: [
            ["date": "2024-01-01", "name": "USD"],
            ["date": "2024-01-01", "name": "HOOL"]
        ],
        documents: [
            [
                "date": "2024-01-03", "account": "Assets:Cash", "filename": "/receipts/jan.pdf",
                "tags": ["scanned"], "links": ["batch-1"]
            ]
        ],
        notes: [
            ["date": "2024-01-04", "account": "Assets:Cash", "comment": "called the bank"]
        ],
        events: [
            ["date": "2024-01-01", "type": "location", "description": "Taipei"]
        ],
        closes: [
            ["account": "Expenses:Food", "close": "2024-06-30"]
        ],
        diagnostics: [
            [
                "file": "/ledger/main.beancount", "line": 20, "column": 1, "end_line": 22, "end_column": 1,
                "severity": "error", "phase": "validate", "code": "E8001",
                "message": "Document file not found: /receipts/jan.pdf"
            ]
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
        costCurrency: String? = nil,
        line: Int? = nil,
        entryMeta: [String: Any]? = nil,
        postingMeta: [String: Any]? = nil,
        tags: [String]? = nil,
        links: [String]? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "date": "2024-01-05", "flag": "*", "payee": payee, "narration": narration,
            "account": account, "number": number, "currency": currency
        ]
        row["cost_number"] = costNumber
        row["cost_currency"] = costCurrency
        if let line {
            row["filename"] = "/ledger/main.beancount"
            row["lineno"] = line
            row["location"] = "/ledger/main.beancount:\(line)"
        }
        row["_entry_meta"] = entryMeta
        row["_posting_meta"] = postingMeta
        row["tags"] = tags
        row["links"] = links
        return row
    }

    private static func position(account: String, number: String, currency: String) -> [String: Any] {
        ["account": account, "balance": ["positions": [["number": number, "currency": currency]]]]
    }
}
