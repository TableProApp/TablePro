//
//  BeancountProjectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("Beancount SQL projection")
struct BeancountProjectionTests {
    @Test("projects transactions and full posting semantics")
    func projectsTransactionsAndPostings() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let transactions = try await driver.execute(query: "SELECT id, payee, narration FROM transactions ORDER BY id")
        #expect(transactions.rows.map { $0.map(\.asText) } == [
            ["1", "Cafe", "Coffee"],
            ["2", "Broker", "Buy stock"],
            ["3", "Archive", "No postings"]
        ])

        let postings = try await driver.execute(query: """
            SELECT transaction_id, account, amount, commodity, flag,
                   cost_number, cost_currency, cost_date, cost_label,
                   price_number, price_currency
            FROM postings ORDER BY id
            """)
        #expect(postings.rows.map { $0.map(\.asText) } == [
            ["1", "Expenses:Food", "4.00", "USD", nil, nil, nil, nil, nil, nil, nil],
            ["1", "Assets:Cash", "-4.00", "USD", nil, nil, nil, nil, nil, nil, nil],
            [
                "2", "Assets:Stock", "10", "HOOL", "!", "100.00", "USD", "2023-12-31", "opening-lot",
                "110", "USD"
            ],
            ["2", "Assets:Cash", "-1000.00", "USD", nil, nil, nil, nil, nil, nil, nil]
        ])

        let postingFreeCount = try await driver.execute(query: """
            SELECT COUNT(*) FROM postings WHERE transaction_id = 3
            """)
        #expect(postingFreeCount.rows.first?.first?.asText == "0")
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

    @Test("projects pad directives with source locations")
    func projectsPads() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let pads = try await driver.execute(query: """
            SELECT date, account, source_account, source_file, line, source_location FROM pads
            """)
        #expect(pads.rows.map { $0.map(\.asText) } == [[
            "2024-01-30",
            "Assets:Cash",
            "Equity:Opening-Balances",
            Self.ledgerURL.path,
            "40",
            "\(Self.ledgerURL.path):40"
        ]])
    }

    @Test("projects a generated pad with no source position rather than dropping it")
    func projectsGeneratedPadWithoutSourcePosition() async throws {
        var rows = Self.cannedRows
        rows.pads = [[
            "date": "2024-02-15",
            "account": "Assets:Cash",
            "source_account": "Equity:Opening-Balances",
            "filename": "<generated>",
            "lineno": 0
        ]]
        let handle = try BeancountPluginDriver.loadProjection(rows: rows, sourceFiles: [Self.ledgerURL])
        let driver = BeancountPluginDriver(
            config: DriverConnectionConfig(
                host: "", port: 0, username: "", password: "", database: Self.ledgerURL.path
            )
        )
        driver.installProjection(handle, ledgerURL: Self.ledgerURL)
        defer { driver.disconnect() }

        let pads = try await driver.execute(query: """
            SELECT date, account, source_account, source_file, line, source_location FROM pads
            """)
        #expect(pads.rows.map { $0.map(\.asText) } == [[
            "2024-02-15",
            "Assets:Cash",
            "Equity:Opening-Balances",
            "<generated>",
            nil,
            nil
        ]])
    }

    @Test("reads pad accounts from a rendered directive")
    func readsPadAccountsFromRenderedDirective() throws {
        let pad = try #require(BeancountPluginDriver.padDirective(
            rendering: "2024-01-30 pad Assets:Cash Equity:Opening-Balances\n"
        ))
        #expect(pad.date == "2024-01-30")
        #expect(pad.account == "Assets:Cash")
        #expect(pad.sourceAccount == "Equity:Opening-Balances")

        let nonBreakingSpace = "Assets:Ca\u{00A0}sh"
        #expect(BeancountPluginDriver.padDirective(
            rendering: "2024-01-30 pad \(nonBreakingSpace) Equity:Opening-Balances\n"
        )?.account == nonBreakingSpace)

        #expect(BeancountPluginDriver.padDirective(rendering: "2024-01-30 open Assets:Cash USD\n") == nil)
        #expect(BeancountPluginDriver.padDirective(rendering: "2024-01-30 balance Assets:Cash 0 USD\n") == nil)
        #expect(BeancountPluginDriver.padDirective(rendering: "2024-01-30 pad Assets:Cash\n") == nil)
        #expect(BeancountPluginDriver.padDirective(rendering: "") == nil)
    }

    @Test("correlates pad entries with rendered directives in order")
    func correlatesPadsWithRenderedDirectives() throws {
        let projection = BeancountPluginDriver.padProjection(
            entries: [
                Self.padEntry(id: 4, date: "2024-02-01", line: 6),
                Self.padEntry(id: 5, date: "2024-05-01", line: 1, file: "/ledger/included.beancount")
            ],
            directives: [
                "2024-01-01 open Assets:Cash USD\n",
                "2024-02-01 pad Assets:Cash Equity:Opening-Balances\n",
                "2024-05-01 pad Assets:Cash Income:Salary\n",
                "2024-12-31 balance Assets:Cash 5.00 USD\n"
            ]
        )
        #expect(projection.diagnostics.isEmpty)
        #expect(projection.rows.count == 2)
        #expect(projection.rows.map { $0["account"] as? String } == ["Assets:Cash", "Assets:Cash"])
        #expect(
            projection.rows.map { $0["source_account"] as? String }
                == ["Equity:Opening-Balances", "Income:Salary"]
        )
    }

    @Test("correlates two pads sharing one date by position")
    func correlatesPadsSharingOneDate() throws {
        let projection = BeancountPluginDriver.padProjection(
            entries: [
                Self.padEntry(id: 4, date: "2024-05-05", line: 6),
                Self.padEntry(id: 5, date: "2024-05-05", line: 7)
            ],
            directives: [
                "2024-05-05 pad Assets:Cash Equity:Charlie\n",
                "2024-05-05 pad Assets:Cash Equity:Alpha\n"
            ]
        )
        #expect(projection.diagnostics.isEmpty)
        #expect(
            projection.rows.map { $0["source_account"] as? String } == ["Equity:Charlie", "Equity:Alpha"]
        )
    }

    @Test("keeps an unparseable pad rendering in place rather than shifting later pads onto it")
    func keepsUnparseablePadRenderingInPlace() throws {
        let projection = BeancountPluginDriver.padProjection(
            entries: [
                Self.padEntry(id: 4, date: "2024-05-05", line: 6),
                Self.padEntry(id: 5, date: "2024-05-05", line: 7)
            ],
            directives: [
                "2024-05-05 pad Assets:Cash\n",
                "2024-05-05 pad Assets:Cash Equity:Bravo\n"
            ]
        )
        #expect(projection.rows.count == 1)
        #expect(projection.rows.first?["source_account"] as? String == "Equity:Bravo")
        #expect(projection.rows.first?["lineno"] as? Int == 7)
        #expect(projection.diagnostics.count == 1)
        #expect(projection.diagnostics.first?["line"] as? Int == 6)
    }

    @Test("reports an uncorrelated pad in diagnostics instead of dropping it silently")
    func reportsUncorrelatedPadsInDiagnostics() throws {
        let dateMismatch = BeancountPluginDriver.padProjection(
            entries: [Self.padEntry(id: 4, date: "2024-02-01", line: 6)],
            directives: ["2024-09-09 pad Assets:Cash Equity:Opening-Balances\n"]
        )
        #expect(dateMismatch.rows.isEmpty)
        #expect(dateMismatch.diagnostics.count == 1)
        #expect(dateMismatch.diagnostics.first?["phase"] as? String == "projection")
        #expect(dateMismatch.diagnostics.first?["severity"] as? String == "warning")
        #expect(dateMismatch.diagnostics.first?["line"] as? Int == 6)
        #expect(dateMismatch.diagnostics.first?["file"] as? String == "/ledger/main.beancount")
        let dateMismatchMessage = try #require(dateMismatch.diagnostics.first?["message"] as? String)
        #expect(!dateMismatchMessage.isEmpty)

        let noDirectives = BeancountPluginDriver.padProjection(
            entries: [Self.padEntry(id: 4, date: "2024-02-01", line: 6)],
            directives: []
        )
        #expect(noDirectives.rows.isEmpty)
        #expect(noDirectives.diagnostics.count == 1)

        let surplusDirectives = BeancountPluginDriver.padProjection(
            entries: [Self.padEntry(id: 4, date: "2024-02-01", line: 6)],
            directives: [
                "2024-02-01 pad Assets:Cash Equity:Opening-Balances\n",
                "2024-03-01 pad Assets:Cash Income:Salary\n"
            ]
        )
        #expect(surplusDirectives.rows.count == 1)
        #expect(surplusDirectives.diagnostics.isEmpty)

        let undatedEntry = BeancountPluginDriver.padProjection(
            entries: [["id": 4, "filename": "/ledger/main.beancount", "lineno": 6]],
            directives: ["2024-02-01 pad Assets:Cash Equity:Opening-Balances\n"]
        )
        #expect(undatedEntry.rows.isEmpty)
        #expect(undatedEntry.diagnostics.count == 1)
    }

    private static func padEntry(
        id: Int,
        date: String,
        line: Int,
        file: String = "/ledger/main.beancount"
    ) -> [String: Any] {
        ["id": id, "date": date, "filename": file, "lineno": line]
    }

    @Test("projects transaction metadata, posting metadata, tags, and links")
    func projectsMetadataTagsAndLinks() async throws {
        let driver = try Self.makeDriver()
        defer { driver.disconnect() }

        let metadata = try await driver.execute(query: """
            SELECT transaction_id, key, value FROM transaction_metadata ORDER BY transaction_id, key
            """)
        #expect(metadata.rows.map { $0.map(\.asText) } == [
            ["1", "invoice", "INV-9"],
            ["1", "reviewed", "TRUE"],
            ["3", "reason", "record only"]
        ])

        let postingMetadata = try await driver.execute(query: """
            SELECT posting_id, key, value FROM posting_metadata ORDER BY id
            """)
        #expect(postingMetadata.rows.map { $0.map(\.asText) } == [["1", "method", "card"]])

        let tags = try await driver.execute(query: """
            SELECT transaction_id, tag FROM transaction_tags ORDER BY transaction_id, tag
            """)
        #expect(tags.rows.map { $0.map(\.asText) } == [
            ["1", "coffee"], ["1", "daily"], ["3", "empty"]
        ])

        let links = try await driver.execute(query: """
            SELECT transaction_id, link FROM transaction_links ORDER BY transaction_id, link
            """)
        #expect(links.rows.map { $0.map(\.asText) } == [["1", "receipt-123"], ["3", "standalone"]])
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
            ["2", nil, nil, nil],
            ["3", "/ledger/main.beancount", "30", "/ledger/main.beancount:30"]
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

    @Test("rejects postings whose transaction is missing")
    func rejectsOrphanPostings() {
        let rows = BeancountProjectionRows(
            postings: [
                Self.postingRow(
                    transactionID: 99,
                    account: "Assets:Cash",
                    number: "1.00",
                    currency: "USD"
                )
            ]
        )

        #expect(throws: BeancountDriverError.self) {
            _ = try BeancountPluginDriver.loadProjection(rows: rows, sourceFiles: [])
        }
    }

    @Test("backfills legacy transaction details without using posting locations")
    func backfillsLegacyTransactionDetails() {
        let transactions: [[String: Any]] = [
            [
                "id": 1,
                "tags": ["entry"],
                "links": ["entry-link"],
                "_entry_meta": ["source": "entry"]
            ],
            ["id": 2]
        ]
        let postings: [[String: Any]] = [
            [
                "transaction_id": 1,
                "tags": ["posting"],
                "links": ["posting-link"],
                "_entry_meta": ["source": "posting"]
            ],
            [
                "transaction_id": 2,
                "tags": ["legacy"],
                "links": ["legacy-link"],
                "_entry_meta": ["source": "legacy"],
                "filename": "/ledger/posting.beancount",
                "lineno": 22
            ]
        ]

        let enriched = BeancountPluginDriver.transactionRowsByAddingPostingDetails(
            transactions,
            postings: postings
        )

        #expect(enriched[0]["tags"] as? [String] == ["entry"])
        #expect(enriched[0]["links"] as? [String] == ["entry-link"])
        #expect((enriched[0]["_entry_meta"] as? [String: String])?["source"] == "entry")
        #expect(enriched[1]["tags"] as? [String] == ["legacy"])
        #expect(enriched[1]["links"] as? [String] == ["legacy-link"])
        #expect((enriched[1]["_entry_meta"] as? [String: String])?["source"] == "legacy")
        #expect(enriched[1]["filename"] == nil)
        #expect(enriched[1]["lineno"] == nil)
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
        transactions: [
            transactionRow(
                id: 1,
                payee: "Cafe",
                narration: "Coffee",
                line: 10,
                metadata: ["invoice": "INV-9", "reviewed": true],
                tags: ["coffee", "daily"],
                links: ["receipt-123"]
            ),
            transactionRow(id: 2, payee: "Broker", narration: "Buy stock"),
            transactionRow(
                id: 3,
                payee: "Archive",
                narration: "No postings",
                line: 30,
                metadata: ["reason": "record only"],
                tags: ["empty"],
                links: ["standalone"]
            )
        ],
        postings: [
            postingRow(
                transactionID: 1,
                account: "Expenses:Food",
                number: "4.00",
                currency: "USD",
                line: 11,
                metadata: ["method": "card"]
            ),
            postingRow(transactionID: 1, account: "Assets:Cash", number: "-4.00", currency: "USD", line: 12),
            postingRow(
                transactionID: 2,
                account: "Assets:Stock",
                number: "10",
                currency: "HOOL",
                costNumber: "100.00",
                costCurrency: "USD",
                costDate: "2023-12-31",
                costLabel: "opening-lot",
                priceNumber: "110",
                priceCurrency: "USD",
                flag: "!"
            ),
            postingRow(transactionID: 2, account: "Assets:Cash", number: "-1000.00", currency: "USD")
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
        pads: [
            [
                "date": "2024-01-30",
                "account": "Assets:Cash",
                "source_account": "Equity:Opening-Balances",
                "filename": ledgerURL.path,
                "lineno": 40,
                "location": "\(ledgerURL.path):40"
            ]
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

    private static func transactionRow(
        id: Int,
        payee: String,
        narration: String,
        line: Int? = nil,
        metadata: [String: Any]? = nil,
        tags: [String]? = nil,
        links: [String]? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id,
            "date": "2024-01-05",
            "flag": "*",
            "payee": payee,
            "narration": narration
        ]
        if let line {
            row["filename"] = "/ledger/main.beancount"
            row["lineno"] = line
            row["location"] = "/ledger/main.beancount:\(line)"
        }
        row["_entry_meta"] = metadata
        row["tags"] = tags
        row["links"] = links
        return row
    }

    private static func postingRow(
        transactionID: Int,
        account: String,
        number: String,
        currency: String,
        costNumber: String? = nil,
        costCurrency: String? = nil,
        costDate: String? = nil,
        costLabel: String? = nil,
        priceNumber: String? = nil,
        priceCurrency: String? = nil,
        flag: String? = nil,
        line: Int? = nil,
        metadata: [String: Any]? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "transaction_id": transactionID,
            "date": "2024-01-05",
            "account": account,
            "number": number,
            "currency": currency
        ]
        row["cost_number"] = costNumber
        row["cost_currency"] = costCurrency
        row["cost_date"] = costDate
        row["cost_label"] = costLabel
        if let priceNumber, let priceCurrency {
            row["price"] = ["number": priceNumber, "currency": priceCurrency]
        }
        row["posting_flag"] = flag
        if let line {
            row["filename"] = "/ledger/main.beancount"
            row["lineno"] = line
            row["location"] = "/ledger/main.beancount:\(line)"
        }
        row["_posting_meta"] = metadata
        return row
    }

    private static func position(account: String, number: String, currency: String) -> [String: Any] {
        ["account": account, "balance": ["positions": [["number": number, "currency": currency]]]]
    }
}
