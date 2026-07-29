//
//  BeancountPluginDriverTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

private enum RustledgerLocator {
    static let path: String? = resolve()

    static func resolve() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TABLEPRO_RUSTLEDGER_BINARY"] {
            candidates.append(env)
        }

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("rledger").path }
        candidates.append(contentsOf: pathCandidates)

        candidates.append(contentsOf: ["/opt/homebrew/bin/rledger", "/usr/local/bin/rledger"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private enum PythonBeancountLocator {
    static let path: String? = resolve()

    static func resolve() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["TABLEPRO_BEANCOUNT_PYTHON"] {
            candidates.append(env)
        }

        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3").path }
        candidates.append(contentsOf: pathCandidates)

        candidates.append(contentsOf: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && canImportBeancount($0) }
    }

    private static func canImportBeancount(_ executablePath: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-c", "import beancount"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@Suite(
    "Beancount plugin driver",
    .serialized
)
struct BeancountPluginDriverTests {
    @Test(
        "reloads the SQL projection when an included ledger file changes",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func reloadsWhenIncludedFileChanges() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let included = directory.appendingPathComponent("accounts.beancount")
            try "2024-01-01 open Assets:Bank:Checking USD\n"
                .write(to: included, atomically: true, encoding: .utf8)

            let ledger = directory.appendingPathComponent("main.beancount")
            try "include \"accounts.beancount\"\n".write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            var result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
            #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking"])

            try """
            2024-01-01 open Assets:Bank:Checking USD
            2024-01-02 open Expenses:Food USD
            """.write(to: included, atomically: true, encoding: .utf8)

            result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
            #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking", "Expenses:Food"])
        }
    }

    @Test(
        "reloads the SQL projection when a glob include matches a new file",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func reloadsWhenGlobIncludeMatchesNewFile() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let imports = directory.appendingPathComponent("imports", isDirectory: true)
            try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
            try "2024-01-01 open Assets:Bank:Checking USD\n"
                .write(to: imports.appendingPathComponent("accounts.beancount"), atomically: true, encoding: .utf8)

            let ledger = directory.appendingPathComponent("main.beancount")
            try "include \"imports/*.beancount\"\n".write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            var result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
            #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking"])

            try "2024-01-02 open Expenses:Food USD\n"
                .write(to: imports.appendingPathComponent("expenses.beancount"), atomically: true, encoding: .utf8)

            result = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
            #expect(result.rows.map { $0[0].asText } == ["Assets:Bank:Checking", "Expenses:Food"])
        }
    }

    @Test(
        "rejects write queries",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func rejectsWriteQueries() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try "2024-01-01 open Assets:Bank:Checking USD\n".write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            await #expect(throws: BeancountDriverError.self) {
                _ = try await driver.execute(query: "DELETE FROM accounts")
            }
        }
    }

    @Test(
        "projects authoritative posting amounts and resolved cost basis",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func projectsAuthoritativeAmounts() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Assets:Stock HOOL

            2024-01-05 * "Broker" "Buy stock"
              Assets:Stock        10 HOOL {100.00 USD}
              Assets:Cash    -1,000.00 USD
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let result = try await driver.execute(query: """
                SELECT account, amount, commodity, cost_number, cost_currency
                FROM postings ORDER BY account
                """)
            let byAccount = Dictionary(
                uniqueKeysWithValues: result.rows.compactMap { row -> (String, [PluginCellValue])? in
                    guard let account = row[0].asText else { return nil }
                    return (account, row)
                }
            )

            let cash = try #require(byAccount["Assets:Cash"])
            #expect(cash[1].asText == "-1000.00")
            #expect(cash[2].asText == "USD")

            let stock = try #require(byAccount["Assets:Stock"])
            #expect(stock[1].asText == "10")
            #expect(stock[2].asText == "HOOL")
            #expect(stock[3].asText == "100.00")
            #expect(stock[4].asText == "USD")
        }
    }

    @Test(
        "projects computed balances from postings",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func projectsComputedBalancesFromPostings() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Expenses:Food USD
            2024-01-01 open Income:Salary USD

            2024-01-05 * "Employer" "Pay"
              Assets:Cash   10.00 USD
              Income:Salary

            2024-01-06 * "Cafe" "Coffee"
              Expenses:Food   3.00 USD
              Assets:Cash
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let result = try await driver.execute(query: """
                SELECT account, amount, commodity
                FROM balances ORDER BY account, commodity
                """)
            #expect(result.rows.map { $0.map(\.asText) } == [
                ["Assets:Cash", "7.00", "USD"],
                ["Expenses:Food", "3.00", "USD"],
                ["Income:Salary", "-10.00", "USD"]
            ])
        }
    }

    @Test(
        "projects balance assertions separately",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func projectsBalanceAssertionsSeparately() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Income:Salary USD

            2024-01-05 * "Employer" "Pay"
              Assets:Cash   10.00 USD
              Income:Salary

            2024-01-31 balance Assets:Cash 10.00 USD
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let result = try await driver.execute(query: """
                SELECT date, account, amount, commodity
                FROM balance_assertions
                """)
            #expect(result.rows.map { $0.map(\.asText) } == [
                ["2024-01-31", "Assets:Cash", "10.00", "USD"]
            ])
        }
    }

    @Test(
        "links postings to a single transaction row",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func linksPostingsToTransaction() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Expenses:Food USD

            2024-01-05 * "Cafe" "Coffee"
              Expenses:Food   4.00 USD
              Assets:Cash    -4.00 USD
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let transactions = try await driver.execute(query: "SELECT id, payee, narration FROM transactions")
            #expect(transactions.rows.count == 1)
            #expect(transactions.rows.first?[1].asText == "Cafe")

            let transactionId = try #require(transactions.rows.first?[0].asText)
            let postings = try await driver.execute(query: "SELECT transaction_id FROM postings")
            #expect(postings.rows.count == 2)
            #expect(postings.rows.allSatisfy { $0[0].asText == transactionId })
        }
    }

    @Test(
        "opens a ledger through the Python Beancount backend",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func opensLedgerThroughPythonBeancountBackend() async throws {
        let python = try #require(PythonBeancountLocator.path)
        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python
        ]) {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Cash USD
            2024-01-01 open Expenses:Food USD
            2024-01-01 open Income:Salary USD

            2024-01-05 * "Employer" "Pay"
              Assets:Cash   10.00 USD
              Income:Salary

            2024-01-06 * "Cafe" "Coffee"
              Expenses:Food   3.00 USD
              Assets:Cash

            2024-01-31 balance Assets:Cash 7.00 USD
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let balances = try await driver.execute(query: """
                SELECT account, amount, commodity
                FROM balances ORDER BY account, commodity
                """)
            #expect(balances.rows.map { $0.map(\.asText) } == [
                ["Assets:Cash", "7.00", "USD"],
                ["Expenses:Food", "3.00", "USD"],
                ["Income:Salary", "-10.00", "USD"]
            ])

            let assertions = try await driver.execute(query: """
                SELECT date, account, amount, commodity
                FROM balance_assertions
                """)
            #expect(assertions.rows.map { $0.map(\.asText) } == [
                ["2024-01-31", "Assets:Cash", "7.00", "USD"]
            ])
        }
    }

    @Test(
        "executes BQL queries through the rledger executable",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func executesBQLQueriesThroughRustledgerExecutable() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            2024-01-01 open Assets:Bank:Checking USD
            2024-01-01 open Expenses:Food USD
            2024-01-01 open Income:Salary USD
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let result = try await driver.execute(query: "BQL: SELECT account FROM accounts ORDER BY account")
            #expect(result.columns == ["account"])
            #expect(result.rows.map { $0.first?.asText } == [
                "Assets:Bank:Checking",
                "Expenses:Food",
                "Income:Salary"
            ])

            let count = try await driver.fetchRowCount(query: "BQL: SELECT account FROM accounts ORDER BY account")
            #expect(count == 3)

            let page = try await driver.fetchRows(
                query: "BQL: SELECT account FROM accounts ORDER BY account",
                offset: 1,
                limit: 1
            )
            #expect(page.rows.map { $0.first?.asText } == ["Expenses:Food"])
        }
    }

    @Test("fails clearly when TABLEPRO_RUSTLEDGER_BINARY points at a missing executable")
    func failsClearlyWhenConfiguredRustledgerIsMissing() async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = directory.appendingPathComponent("main.beancount")
        try "2024-01-01 open Assets:Bank:Checking USD\n"
            .write(to: ledger, atomically: true, encoding: .utf8)

        let missing = directory.appendingPathComponent("missing-rledger").path
        try await Self.withRustledgerEnvironment(missing) {
            let driver = BeancountPluginDriver(config: Self.config(ledger))
            do {
                try await driver.connect()
                Issue.record("Expected missing rledger configuration to fail")
            } catch let error as BeancountDriverError {
                let message = error.errorDescription ?? ""
                #expect(message.contains("TABLEPRO_RUSTLEDGER_BINARY"))
                #expect(message.contains(missing))
            } catch {
                Issue.record("Expected BeancountDriverError, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    private static func withRustledger(_ body: () async throws -> Void) async throws {
        let rledger = try #require(RustledgerLocator.path)
        try await withRustledgerEnvironment(rledger, body)
    }

    private static func withRustledgerEnvironment(_ path: String, _ body: () async throws -> Void) async throws {
        try await withEnvironment(["TABLEPRO_RUSTLEDGER_BINARY": path], body)
    }

    private static func withEnvironment(
        _ values: [String: String],
        _ body: () async throws -> Void
    ) async throws {
        let previous = values.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        for (name, value) in values {
            setenv(name, value, 1)
        }
        defer {
            for (name, previousValue) in previous {
                if let previousValue {
                    setenv(name, previousValue, 1)
                } else {
                    unsetenv(name)
                }
            }
        }
        try await body()
    }

    private static func config(_ ledger: URL) -> DriverConnectionConfig {
        DriverConnectionConfig(host: "", port: 0, username: "", password: "", database: ledger.path)
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
