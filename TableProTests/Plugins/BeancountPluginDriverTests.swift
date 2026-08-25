//
//  BeancountPluginDriverTests.swift
//  TableProTests
//

import Darwin
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
        "projects posting semantics through rledger",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func projectsPostingSemanticsThroughRustledger() async throws {
        try await Self.withRustledger {
            try await Self.withPostingSemanticsLedger(Self.expectPostingSemantics)
        }
    }

    @Test(
        "projects posting semantics through Python Beancount",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func projectsPostingSemanticsThroughPythonBeancount() async throws {
        let python = try #require(PythonBeancountLocator.path)
        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python
        ]) {
            try await Self.withPostingSemanticsLedger(Self.expectPostingSemantics)
        }
    }

    @Test(
        "keeps posting source locations and metadata when the backend lacks the semantic columns",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func keepsPostingSourceDetailWhenSemanticColumnsAreUnsupported() async throws {
        let rledger = try #require(RustledgerLocator.path)
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let wrapper = directory.appendingPathComponent("rledger")
        try """
        #!/bin/sh
        for argument in "$@"; do
          case "$argument" in
            *posting_flag*)
              echo "evaluation error: column 'posting_flag' not found in subquery result" >&2
              exit 1
              ;;
          esac
        done
        exec "\(rledger)" "$@"
        """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 open Assets:Cash USD
        2024-01-01 open Expenses:Food USD

        2024-01-05 * "Cafe" "Coffee"
          Expenses:Food  3.00 USD
            method: "card"
          Assets:Cash
        """.write(to: ledger, atomically: true, encoding: .utf8)

        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "rledger",
            "TABLEPRO_RUSTLEDGER_BINARY": wrapper.path
        ]) {
            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let postings = try await driver.execute(query: """
                SELECT account, flag, price_number, line FROM postings ORDER BY account
                """)
            #expect(postings.rows.map { $0.map(\.asText) } == [
                ["Assets:Cash", nil, nil, "7"],
                ["Expenses:Food", nil, nil, "5"]
            ])

            let metadata = try await driver.execute(query: """
                SELECT key, value FROM posting_metadata ORDER BY key
                """)
            #expect(metadata.rows.map { $0.map(\.asText) } == [["method", "card"]])
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

    @Test("reads the ledger plugin trust flag from the connection, not the environment")
    func readsLedgerPluginTrustFromConnection() {
        #expect(BeancountPluginDriver.allowsLedgerPlugins([:]) == false)
        #expect(BeancountPluginDriver.allowsLedgerPlugins(["beancountRunLedgerPlugins": "false"]) == false)
        #expect(BeancountPluginDriver.allowsLedgerPlugins(["beancountRunLedgerPlugins": "true"]))
    }

    @Test(
        "does not run ledger-declared Python plugins for an untrusted connection",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func doesNotRunLedgerDeclaredPythonPluginsWhenUntrusted() async throws {
        try await Self.withPythonBeancount { directory in
            let marker = directory.appendingPathComponent("plugin-executed")
            let ledger = try Self.writeMarkerPluginLedger(in: directory, marker: marker)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            #expect(!FileManager.default.fileExists(atPath: marker.path))
            let diagnostics = try await driver.execute(query: """
                SELECT phase, severity, message FROM diagnostics WHERE phase = 'security'
                """)
            #expect(diagnostics.rows.count == 1)
            #expect(diagnostics.rows.first?[1].asText == "warning")
            #expect(diagnostics.rows.first?[2].asText?.contains("tablepro_marker_plugin") == true)
        }
    }

    @Test(
        "runs ledger-declared Python plugins for a trusted connection",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func runsLedgerDeclaredPythonPluginsWhenTrusted() async throws {
        try await Self.withPythonBeancount { directory in
            let marker = directory.appendingPathComponent("plugin-executed")
            let ledger = try Self.writeMarkerPluginLedger(in: directory, marker: marker)

            let driver = BeancountPluginDriver(
                config: Self.config(ledger, additionalFields: ["beancountRunLedgerPlugins": "true"])
            )
            try await driver.connect()
            defer { driver.disconnect() }

            #expect(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test(
        "keeps running the plugins that ship with Beancount",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func keepsRunningPluginsThatShipWithBeancount() async throws {
        try await Self.withPythonBeancount { directory in
            let ledger = directory.appendingPathComponent("main.beancount")
            try """
            plugin "beancount.plugins.auto_accounts"

            2024-01-02 * "Cafe" "Coffee"
              Expenses:Food  3.00 USD
              Assets:Cash
            """.write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let accounts = try await driver.execute(query: "SELECT name FROM accounts ORDER BY name")
            #expect(accounts.rows.map { $0[0].asText } == ["Assets:Cash", "Expenses:Food"])

            let diagnostics = try await driver.execute(query: """
                SELECT message FROM diagnostics WHERE phase = 'security'
                """)
            #expect(diagnostics.rows.isEmpty)
        }
    }

    @Test("reports the active Python Beancount backend and version")
    func reportsActivePythonBeancountBackendAndVersion() async throws {
        try await Self.withFakePythonBackend(reportedVersion: "3.2.3") { _, ledger in
            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            #expect(driver.serverVersion == "Python Beancount 3.2.3")
        }
    }

    @Test("names the backend without a version when the executable reports none")
    func namesBackendWithoutVersionWhenExecutableReportsNone() async throws {
        try await Self.withFakePythonBackend(reportedVersion: "") { _, ledger in
            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            #expect(driver.serverVersion == "Python Beancount")
        }
    }

    @Test("measures a backend version once per executable, not once per projection")
    func measuresBackendVersionOncePerExecutable() async throws {
        try await Self.withFakePythonBackend(reportedVersion: "3.2.3") { directory, ledger in
            for _ in 0..<3 {
                let driver = BeancountPluginDriver(config: Self.config(ledger))
                try await driver.connect()
                driver.disconnect()
            }

            let calls = try String(
                contentsOf: directory.appendingPathComponent("version-calls"),
                encoding: .utf8
            )
            #expect(calls.split(separator: "\n").count == 1)
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

    @Test(
        "projects rich directives and posting-free transactions through rledger",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func projectsRichDirectivesThroughRustledger() async throws {
        try await Self.withRustledger {
            try await Self.withRichDirectiveLedger { driver, ledger in
                try await Self.expectRichDirectives(driver, ledger: ledger)
            }
        }
    }

    @Test(
        "projects rich directives and posting-free transactions through Python Beancount",
        .enabled(if: PythonBeancountLocator.path != nil, "Python Beancount unavailable")
    )
    func projectsRichDirectivesThroughPythonBeancount() async throws {
        let python = try #require(PythonBeancountLocator.path)
        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python
        ]) {
            try await Self.withRichDirectiveLedger { driver, ledger in
                try await Self.expectRichDirectives(driver, ledger: ledger)
            }
        }
    }

    @Test(
        "projects the same core relations through both Beancount backends",
        .enabled(
            if: RustledgerLocator.path != nil && PythonBeancountLocator.path != nil,
            "rledger and Python Beancount are both required"
        )
    )
    func projectsSameCoreRelationsThroughBothBackends() async throws {
        let rledger = try #require(RustledgerLocator.path)
        let python = try #require(PythonBeancountLocator.path)
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 commodity USD
        2024-01-01 open Assets:Cash USD
        2024-01-01 open Expenses:Food USD

        2024-01-02 * "Cafe" "Coffee"
          Expenses:Food  3.00 USD
          Assets:Cash

        2024-01-03 price USD 0.92 EUR
        2024-01-04 balance Assets:Cash -3.00 USD
        2024-01-05 event "location" "Taipei"
        2024-01-06 note Assets:Cash "checked"
        2024-06-30 close Expenses:Food
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let rustledgerRows = try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "rledger",
            "TABLEPRO_RUSTLEDGER_BINARY": rledger
        ]) {
            try await Self.coreProjectionSnapshot(ledger: ledger)
        }
        let pythonRows = try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python
        ]) {
            try await Self.coreProjectionSnapshot(ledger: ledger)
        }

        #expect(rustledgerRows == pythonRows)
    }

    @Test(
        "refreshes document diagnostics when an included document target changes",
        .enabled(if: RustledgerLocator.path != nil, "rledger executable unavailable")
    )
    func refreshesDocumentDiagnostics() async throws {
        try await Self.withRustledger {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let subdirectory = directory.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let included = subdirectory.appendingPathComponent("entries.beancount")
            try """
            2024-01-01 open Assets:Cash USD

            2024-01-04 document Assets:Cash "receipt.pdf"
            """.write(to: included, atomically: true, encoding: .utf8)

            let ledger = directory.appendingPathComponent("main.beancount")
            try "include \"sub/entries.beancount\"\n"
                .write(to: ledger, atomically: true, encoding: .utf8)

            let driver = BeancountPluginDriver(config: Self.config(ledger))
            try await driver.connect()
            defer { driver.disconnect() }

            let accounts = try await driver.execute(query: "SELECT name FROM accounts")
            #expect(accounts.rows.map { $0[0].asText } == ["Assets:Cash"])

            var diagnostics = try await driver.execute(query: """
                SELECT source_file, line, source_location FROM diagnostics
                WHERE code = 'E8001' ORDER BY id
                """)
            #expect(diagnostics.rows.count == 1)
            let diagnostic = try #require(diagnostics.rows.first)
            let sourceFile = try #require(diagnostic[0].asText)
            #expect(Self.canonicalPath(URL(fileURLWithPath: sourceFile)) == Self.canonicalPath(included))
            #expect(diagnostic[1].asText == "3")
            #expect(diagnostic[2].asText == "\(sourceFile):3")

            let document = subdirectory.appendingPathComponent("receipt.pdf")
            try Data("pdf".utf8).write(to: document)

            diagnostics = try await driver.execute(query: """
                SELECT source_file, line, source_location FROM diagnostics
                WHERE code = 'E8001' ORDER BY id
                """)
            #expect(diagnostics.rows.isEmpty)

            try FileManager.default.removeItem(at: document)

            diagnostics = try await driver.execute(query: """
                SELECT source_file, line, source_location FROM diagnostics
                WHERE code = 'E8001' ORDER BY id
                """)
            #expect(diagnostics.rows.count == 1)
            let returned = try #require(diagnostics.rows.first)
            let returnedSourceFile = try #require(returned[0].asText)
            #expect(Self.canonicalPath(URL(fileURLWithPath: returnedSourceFile)) == Self.canonicalPath(included))
            #expect(returned[1].asText == "3")
            #expect(returned[2].asText == "\(returnedSourceFile):3")
        }
    }

    private static func withRichDirectiveLedger(
        _ body: (BeancountPluginDriver, URL) async throws -> Void
    ) async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("pdf".utf8).write(to: directory.appendingPathComponent("receipt.pdf"))

        let padsLedger = directory.appendingPathComponent("pads.beancount")
        let crlfPadsLedger = [
            "2024-01-01 open Equity:Opening-Balances USD",
            "",
            "2024/06/28 pad Assets:Cash Equity:Opening-Balances;opening",
            "2024-06-29 balance Assets:Cash 0 USD"
        ].joined(separator: "\r\n")
        try crlfPadsLedger.write(to: padsLedger, atomically: true, encoding: .utf8)

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        2024-01-01 commodity USD
          name: "US Dollar"

        2024-01-01 open Assets:Cash USD
        2024-01-01 open Expenses:Food USD

        2024-01-02 event "location" "Taipei"

        2024-01-03 note Assets:Cash "called the bank"

        2024-01-04 document Assets:Cash "receipt.pdf"

        2024-01-05 * "Cafe" "Coffee" #coffee #daily ^receipt-123
          invoice: "INV-9"
          verified: TRUE
          Expenses:Food   3.00 USD
            method: "card"
          Assets:Cash

        2024-01-06 * "Archive" "No postings" #empty ^standalone
          reason: "record only"

        include "pads.beancount"

        2024-06-30 close Expenses:Food
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let driver = BeancountPluginDriver(config: Self.config(ledger))
        try await driver.connect()
        defer { driver.disconnect() }

        try await body(driver, ledger)
    }

    private static func withPostingSemanticsLedger(
        _ body: (BeancountPluginDriver) async throws -> Void
    ) async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        2023-12-31 open Assets:Brokerage HOOL
        2023-12-31 open Assets:Cash USD

        2024-01-02 * "Broker" "Buy"
          ! Assets:Brokerage  2 HOOL {100 USD, 2023-12-31, "opening-lot"} @ 110 USD
          Assets:Cash       -200 USD
        """.write(to: ledger, atomically: true, encoding: .utf8)

        let driver = BeancountPluginDriver(config: Self.config(ledger))
        try await driver.connect()
        defer { driver.disconnect() }

        try await body(driver)
    }

    private static func expectPostingSemantics(_ driver: BeancountPluginDriver) async throws {
        let result = try await driver.execute(query: """
            SELECT account, amount, commodity, flag,
                   cost_number, cost_currency, cost_date, cost_label,
                   price_number, price_currency
            FROM postings ORDER BY account
            """)
        #expect(result.rows.map { $0.map(\.asText) } == [
            ["Assets:Brokerage", "2", "HOOL", "!", "100", "USD", "2023-12-31", "opening-lot", "110", "USD"],
            ["Assets:Cash", "-200", "USD", nil, nil, nil, nil, nil, nil, nil]
        ])
    }

    private static func expectRichDirectives(_ driver: BeancountPluginDriver, ledger: URL) async throws {
        let commodities = try await driver.execute(query: "SELECT date, commodity FROM commodities")
        #expect(commodities.rows.map { $0.map(\.asText) } == [["2024-01-01", "USD"]])

        let events = try await driver.execute(query: "SELECT date, type, description FROM events")
        #expect(events.rows.map { $0.map(\.asText) } == [["2024-01-02", "location", "Taipei"]])

        let notes = try await driver.execute(query: "SELECT date, account, comment FROM notes")
        #expect(notes.rows.map { $0.map(\.asText) } == [["2024-01-03", "Assets:Cash", "called the bank"]])

        let closes = try await driver.execute(query: "SELECT date, account FROM closes")
        #expect(closes.rows.map { $0.map(\.asText) } == [["2024-06-30", "Expenses:Food"]])

        let pads = try await driver.execute(query: """
            SELECT date, account, source_account, source_file, line, source_location FROM pads
            """)
        #expect(pads.rows.count == 1)
        let pad = try #require(pads.rows.first)
        #expect(pad[0].asText == "2024-06-28")
        #expect(pad[1].asText == "Assets:Cash")
        #expect(pad[2].asText == "Equity:Opening-Balances")
        #expect(pad[3].asText?.hasSuffix("pads.beancount") == true)
        #expect(pad[4].asText == "3")
        #expect(pad[5].asText?.hasSuffix("pads.beancount:3") == true)

        let documents = try await driver.execute(query: "SELECT date, account, path FROM documents")
        #expect(documents.rows.count == 1)
        let document = try #require(documents.rows.first)
        #expect(document[0].asText == "2024-01-04")
        #expect(document[1].asText == "Assets:Cash")
        #expect(document[2].asText?.hasSuffix("receipt.pdf") == true)

        let metadata = try await driver.execute(query: """
            SELECT metadata.key, metadata.value
            FROM transaction_metadata AS metadata
            JOIN transactions ON transactions.id = metadata.transaction_id
            WHERE transactions.narration = 'Coffee'
            ORDER BY metadata.key
            """)
        #expect(metadata.rows.map { $0.map(\.asText) } == [["invoice", "INV-9"], ["verified", "TRUE"]])

        let postingMetadata = try await driver.execute(query: """
            SELECT metadata.key, metadata.value
            FROM posting_metadata AS metadata
            JOIN postings ON postings.id = metadata.posting_id
            JOIN transactions ON transactions.id = postings.transaction_id
            WHERE transactions.narration = 'Coffee'
            """)
        #expect(postingMetadata.rows.map { $0.map(\.asText) } == [["method", "card"]])

        let tags = try await driver.execute(query: """
            SELECT tags.tag
            FROM transaction_tags AS tags
            JOIN transactions ON transactions.id = tags.transaction_id
            WHERE transactions.narration = 'Coffee'
            ORDER BY tags.tag
            """)
        #expect(tags.rows.map { $0[0].asText } == ["coffee", "daily"])

        let links = try await driver.execute(query: """
            SELECT links.link
            FROM transaction_links AS links
            JOIN transactions ON transactions.id = links.transaction_id
            WHERE transactions.narration = 'Coffee'
            """)
        #expect(links.rows.map { $0[0].asText } == ["receipt-123"])

        let transactions = try await driver.execute(query: """
            SELECT source_file, line, source_location FROM transactions WHERE narration = 'Coffee'
            """)
        #expect(transactions.rows.count == 1)
        let transaction = try #require(transactions.rows.first)
        #expect(transaction[0].asText?.hasSuffix(ledger.lastPathComponent) == true)
        #expect(transaction[1].asText == "13")
        #expect(transaction[2].asText?.hasSuffix("\(ledger.lastPathComponent):13") == true)

        let postings = try await driver.execute(query: """
            SELECT postings.line
            FROM postings
            JOIN transactions ON transactions.id = postings.transaction_id
            WHERE transactions.narration = 'Coffee'
            ORDER BY postings.id
            """)
        #expect(postings.rows.map { $0[0].asText } == ["16", "18"])

        let postingFree = try await driver.execute(query: """
            SELECT id, date, flag, payee, narration, source_file, line, source_location
            FROM transactions WHERE narration = 'No postings'
            """)
        #expect(postingFree.rows.count == 1)
        let transactionWithoutPostings = try #require(postingFree.rows.first)
        #expect(transactionWithoutPostings[0].asText != nil)
        #expect(transactionWithoutPostings.dropFirst().prefix(4).map(\.asText) == [
            "2024-01-06",
            "*",
            "Archive",
            "No postings"
        ])
        let sourceFile = try #require(transactionWithoutPostings[5].asText)
        #expect(Self.canonicalPath(URL(fileURLWithPath: sourceFile)) == Self.canonicalPath(ledger))
        #expect(transactionWithoutPostings[6].asText == "20")
        #expect(transactionWithoutPostings[7].asText == "\(sourceFile):20")

        let postingFreeMetadata = try await driver.execute(query: """
            SELECT metadata.key, metadata.value
            FROM transaction_metadata AS metadata
            JOIN transactions ON transactions.id = metadata.transaction_id
            WHERE transactions.narration = 'No postings'
            ORDER BY metadata.key
            """)
        #expect(postingFreeMetadata.rows.map { $0.map(\.asText) } == [["reason", "record only"]])

        let postingFreeTags = try await driver.execute(query: """
            SELECT tags.tag
            FROM transaction_tags AS tags
            JOIN transactions ON transactions.id = tags.transaction_id
            WHERE transactions.narration = 'No postings'
            ORDER BY tags.tag
            """)
        #expect(postingFreeTags.rows.map { $0[0].asText } == ["empty"])

        let postingFreeLinks = try await driver.execute(query: """
            SELECT links.link
            FROM transaction_links AS links
            JOIN transactions ON transactions.id = links.transaction_id
            WHERE transactions.narration = 'No postings'
            ORDER BY links.link
            """)
        #expect(postingFreeLinks.rows.map { $0[0].asText } == ["standalone"])

        let postingFreeCount = try await driver.execute(query: """
            SELECT COUNT(postings.id)
            FROM transactions
            LEFT JOIN postings ON postings.transaction_id = transactions.id
            WHERE transactions.narration = 'No postings'
            GROUP BY transactions.id
            """)
        #expect(postingFreeCount.rows.first?.first?.asText == "0")
    }

    private static func withRustledger(_ body: () async throws -> Void) async throws {
        let rledger = try #require(RustledgerLocator.path)
        try await withRustledgerEnvironment(rledger, body)
    }

    private static func withRustledgerEnvironment(_ path: String, _ body: () async throws -> Void) async throws {
        try await withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "rledger",
            "TABLEPRO_RUSTLEDGER_BINARY": path
        ], body)
    }

    private static func withEnvironment<T>(
        _ values: [String: String],
        _ body: () async throws -> T
    ) async throws -> T {
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
        return try await body()
    }

    private static func coreProjectionSnapshot(ledger: URL) async throws -> [String: [[String?]]] {
        let driver = BeancountPluginDriver(config: Self.config(ledger))
        try await driver.connect()
        defer { driver.disconnect() }

        // Row ids are per-backend: rledger numbers every entry in the ledger, the Python script
        // numbers only the transactions it walks. Comparing them would never match, so the
        // snapshot compares the values and orders by them.
        let queries = [
            "accounts": "SELECT name, open_date, currencies FROM accounts ORDER BY name",
            "balance_assertions": """
                SELECT date, account, amount, commodity FROM balance_assertions
                ORDER BY date, account, commodity
                """,
            "balances": "SELECT account, amount, commodity FROM balances ORDER BY account, commodity",
            "closes": "SELECT date, account FROM closes ORDER BY date, account",
            "commodities": "SELECT date, commodity FROM commodities ORDER BY date, commodity",
            "events": "SELECT date, type, description FROM events ORDER BY date, type",
            "notes": "SELECT date, account, comment FROM notes ORDER BY date, account",
            "postings": """
                SELECT date, account, amount, commodity FROM postings
                ORDER BY date, account, commodity
                """,
            "prices": "SELECT date, commodity, amount, currency FROM prices ORDER BY date, commodity",
            "transactions": """
                SELECT date, flag, payee, narration FROM transactions
                ORDER BY date, payee, narration
                """
        ]

        var snapshot: [String: [[String?]]] = [:]
        for (table, query) in queries {
            let result = try await driver.execute(query: query)
            snapshot[table] = result.rows.map { $0.map(\.asText) }
        }
        return snapshot
    }

    private static func withFakePythonBackend(
        reportedVersion: String,
        _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let python = directory.appendingPathComponent("python3")
        try """
        #!/bin/sh
        case "$2" in
          *importlib.metadata*)
            echo called >> "$(dirname "$0")/version-calls"
            printf '%s' '\(reportedVersion)'
            ;;
          "import beancount") exit 0 ;;
          *) printf '{"transactions":[]}' ;;
        esac
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let ledger = directory.appendingPathComponent("main.beancount")
        try "".write(to: ledger, atomically: true, encoding: .utf8)

        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python.path
        ]) {
            try await body(directory, ledger)
        }
    }

    private static func config(
        _ ledger: URL,
        additionalFields: [String: String] = [:]
    ) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: "",
            port: 0,
            username: "",
            password: "",
            database: ledger.path,
            additionalFields: additionalFields
        )
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { fileSystemPath in
            guard let fileSystemPath, let resolvedPath = realpath(fileSystemPath, nil) else {
                return url.standardizedFileURL.path
            }
            defer { free(resolvedPath) }
            return String(cString: resolvedPath)
        }
    }

    private static func withPythonBeancount(
        _ body: (URL) async throws -> Void
    ) async throws {
        let python = try #require(PythonBeancountLocator.path)
        try await Self.withEnvironment([
            "TABLEPRO_BEANCOUNT_BACKEND": "python",
            "TABLEPRO_BEANCOUNT_PYTHON": python
        ]) {
            let directory = try Self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            try await body(directory)
        }
    }

    private static func writeMarkerPluginLedger(in directory: URL, marker: URL) throws -> URL {
        try """
        from pathlib import Path

        __plugins__ = ("write_marker",)

        def write_marker(entries, options_map, marker_path):
            Path(marker_path).write_text("executed", encoding="utf-8")
            return entries, []
        """.write(
            to: directory.appendingPathComponent("tablepro_marker_plugin.py"),
            atomically: true,
            encoding: .utf8
        )

        let ledger = directory.appendingPathComponent("main.beancount")
        try """
        option "insert_pythonpath" "TRUE"
        plugin "tablepro_marker_plugin" "\(marker.path)"
        """.write(to: ledger, atomically: true, encoding: .utf8)
        return ledger
    }

    private static func makeTempDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("beancount-driver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
