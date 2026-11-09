import Foundation
@testable import TablePro
import TableProMCP
import TableProTestSupport
import Testing

struct GetTableHealthToolTests {
    private typealias Fixture = TableHealthFixture

    private let orders = Fixture.finding(table: "orders")
    private let invoices = Fixture.finding(table: "invoices")
    private let logs = Fixture.finding(table: "logs")

    private static let day1 = Date(timeIntervalSince1970: 86_400)

    private func report(_ results: [TableHealthCheckResult], notes: [String] = []) -> TableHealthReport {
        TableHealthReport(database: "shop", checks: results, notes: notes, generatedAt: Self.day1)
    }

    private func result(
        _ kind: TableHealthCheckKind,
        _ outcome: TableHealthCheckResult.Outcome,
        _ findings: [TableHealthFinding] = [],
        note: String? = nil
    ) -> TableHealthCheckResult {
        TableHealthCheckResult(
            check: TableHealthCheck(kind: kind, summary: "Summary"),
            findings: findings,
            outcome: outcome,
            note: note
        )
    }

    private func status(of finding: TableHealthFinding, in payload: JsonValue) -> String? {
        payload["findings"]?.arrayValue?
            .first { $0["table"]?.stringValue == finding.table }?["status"]?.stringValue
    }

    private func keys(_ value: JsonValue?) -> Set<String> {
        Set(value?.objectValue.map { Array($0.keys) } ?? [])
    }

    private func required(_ schema: JsonValue?) -> Set<String> {
        Set(schema?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? [])
    }

    @Test("A failed check reaches the client as fixed text, never the server's own words")
    func failedCheckIsFixedText() {
        let payload = MCPConnectionBridge.tableHealthPayload(
            report([result(.bloat, .failed("permission denied for table secrets"))]),
            ledger: TableHealthLedger()
        )

        let check = payload["checks"]?.arrayValue?.first
        #expect(check?["outcome"]?.stringValue == "failed")
        #expect(check?["reason"]?.stringValue == "The server did not answer this check.")
        #expect(!MCPToolCallResult.encodeJsonString(payload).contains("secrets"))
    }

    @Test("A skipped check passes its reason and note through, and report notes come along")
    func skippedCheckKeepsItsReason() {
        let payload = MCPConnectionBridge.tableHealthPayload(
            report(
                [result(.unusedIndex, .skipped("track_counts is off"), note: "Counts since the reset")],
                notes: ["This server is a read-only standby."]
            ),
            ledger: TableHealthLedger()
        )

        let check = payload["checks"]?.arrayValue?.first
        #expect(check?["outcome"]?.stringValue == "skipped")
        #expect(check?["reason"]?.stringValue == "track_counts is off")
        #expect(check?["note"]?.stringValue == "Counts since the reset")
        #expect(payload["notes"] == .array([.string("This server is a read-only standby.")]))
        #expect(payload["database"]?.stringValue == "shop")
        #expect(payload["generated_at"]?.stringValue == "1970-01-02T00:00:00Z")
    }

    @Test("Status comes from the stored history: new since its last run, or ignored")
    func statusFollowsTheLedger() {
        let ledger = TableHealthLedger()
            .recording(report([result(.missingPrimaryKey, .completed, [orders, logs])]), at: Self.day1)
            .ignoring([logs.id], at: Self.day1)

        let payload = MCPConnectionBridge.tableHealthPayload(
            report([result(.missingPrimaryKey, .completed, [orders, logs, invoices])]),
            ledger: ledger
        )

        #expect(status(of: orders, in: payload) == "none")
        #expect(status(of: logs, in: payload) == "ignored")
        #expect(status(of: invoices, in: payload) == "new")
    }

    @Test("With no recorded run there is nothing to compare with, so nothing reads as new")
    func nothingIsNewWithoutHistory() {
        let payload = MCPConnectionBridge.tableHealthPayload(
            report([result(.missingPrimaryKey, .completed, [orders])]),
            ledger: TableHealthLedger()
        )

        #expect(status(of: orders, in: payload) == "none")
    }

    @Test("A finding carries typed metrics and its size, and leaves out what it lacks")
    func findingCarriesTypedValues() throws {
        let finding = TableHealthFinding(
            kind: .nearLimit,
            schema: nil,
            table: "events",
            objectName: nil,
            detail: "Counter near its limit",
            sizeBytes: 4_096,
            metrics: [
                TableHealthMetric(id: "rows", label: "Rows", value: .count(5)),
                TableHealthMetric(id: "next_value", label: "Next", value: .bigCount(UInt64.max)),
                TableHealthMetric(id: "small_next", label: "Next", value: .bigCount(10)),
                TableHealthMetric(id: "size", label: "Size", value: .bytes(2_048)),
                TableHealthMetric(id: "used", label: "Used", value: .percent(0.25)),
                TableHealthMetric(id: "broken", label: "Broken", value: .percent(.nan)),
                TableHealthMetric(id: "seen", label: "Seen", value: .date(Self.day1)),
                TableHealthMetric(id: "type", label: "Type", value: .text("bigint unsigned")),
                TableHealthMetric(id: "unsigned", label: "Unsigned", value: .flag(true))
            ],
            fixSQL: nil
        )
        let payload = MCPConnectionBridge.tableHealthPayload(
            report([result(.nearLimit, .completed, [finding])]),
            ledger: TableHealthLedger()
        )

        let encoded = try #require(payload["findings"]?.arrayValue?.first)
        let fields = keys(encoded)
        #expect(fields == ["kind", "table", "detail", "size_bytes", "metrics", "status"])
        #expect(encoded["kind"]?.stringValue == "nearLimit")
        #expect(encoded["size_bytes"] == .int(4_096))

        let metrics = try #require(encoded["metrics"]?.arrayValue)
        let values = metrics.compactMap { $0["value"] }
        let types = metrics.compactMap { $0["type"]?.stringValue }
        #expect(values == [
            .int(5),
            .string("18446744073709551615"),
            .int(10),
            .int(2_048),
            .double(0.25),
            .null,
            .string("1970-01-02T00:00:00Z"),
            .string("bigint unsigned"),
            .bool(true)
        ])
        #expect(types == ["count", "count", "count", "bytes", "percent", "percent", "date", "text", "flag"])
        #expect(MCPToolCallResult.encodeJsonString(payload) != "{}")
    }

    @Test("Every key the payload sends is declared in the output schema, and every required one is sent")
    func payloadMatchesTheOutputSchema() throws {
        let finding = TableHealthFinding(
            kind: .unusedIndex,
            schema: "public",
            table: "orders",
            objectName: "orders_note_idx",
            detail: "Never scanned",
            sizeBytes: 8_192,
            metrics: [TableHealthMetric.estimatedRows(10)],
            fixSQL: "DROP INDEX public.orders_note_idx;"
        )
        let payload = MCPConnectionBridge.tableHealthPayload(
            report(
                [
                    result(.unusedIndex, .completed, [finding], note: "Counts since the reset"),
                    result(.bloat, .failed("boom")),
                    result(.staleStatistics, .skipped("standby"))
                ],
                notes: ["Note"]
            ),
            ledger: TableHealthLedger()
        )
        let schema = try #require(GetTableHealthTool.outputSchema)
        let checkSchema = schema["properties"]?["checks"]?["items"]
        let findingSchema = schema["properties"]?["findings"]?["items"]
        let metricSchema = findingSchema?["properties"]?["metrics"]?["items"]

        let rootKeys = keys(payload)
        #expect(rootKeys.isSubset(of: keys(schema["properties"])))
        #expect(required(schema).isSubset(of: rootKeys))

        for check in payload["checks"]?.arrayValue ?? [] {
            let checkKeys = keys(check)
            #expect(checkKeys.isSubset(of: keys(checkSchema?["properties"])), "undeclared: \(checkKeys)")
            #expect(required(checkSchema).isSubset(of: checkKeys))
        }

        let encoded = try #require(payload["findings"]?.arrayValue?.first)
        let findingKeys = keys(encoded)
        #expect(findingKeys == keys(findingSchema?["properties"]))
        #expect(required(findingSchema).isSubset(of: findingKeys))

        let metric = encoded["metrics"]?.arrayValue?.first
        #expect(keys(metric) == keys(metricSchema?["properties"]))
        #expect(required(metricSchema) == keys(metric))
    }

    // The stand-in read stays held until after the call has answered, like one queued behind the tab's report on
    // the pool's serial lane, so a race that waited for it would never finish.
    @Test("The MCP query timeout answers at once and tells the checks to stop", .timeLimit(.minutes(1)))
    func timeoutAnswersWithoutWaitingForTheChecks() async {
        let held = AsyncGate()
        let stopped = AsyncGate()
        var thrown: (any Error)?

        do {
            _ = try await MCPConnectionBridge.withinTableHealthTimeout(seconds: 0) {
                try await withTaskCancellationHandler {
                    await held.wait()
                    try Task.checkCancellation()
                    return 1
                } onCancel: {
                    Task { await stopped.open() }
                }
            }
        } catch {
            thrown = error
        }
        await stopped.wait()
        await held.open()

        let mapped = (thrown as? DatabaseAccessError).map { MCPToolExecutionError.from($0) }
        #expect(mapped?.code == .timeout)
        #expect(mapped?.message == "Table Health did not finish within the MCP query timeout of 0 seconds.")
    }

    @Test("A cancelled call answers at once and tells the checks to stop", .timeLimit(.minutes(1)))
    func cancelAnswersWithoutWaitingForTheChecks() async {
        let held = AsyncGate()
        let stopped = AsyncGate()
        let call = Task {
            try await MCPConnectionBridge.withinTableHealthTimeout(seconds: 3_600) {
                try await withTaskCancellationHandler {
                    await held.wait()
                    try Task.checkCancellation()
                    return 1
                } onCancel: {
                    Task { await stopped.open() }
                }
            }
        }

        await held.arrived(1)
        call.cancel()
        let outcome = await call.result
        await stopped.wait()
        await held.open()

        var thrown: (any Error)?
        if case .failure(let error) = outcome {
            thrown = error
        }
        #expect(thrown is CancellationError)
    }

    @Test("An error from the checks reaches the caller as it is")
    func checkErrorPassesThrough() async {
        var thrown: (any Error)?
        do {
            _ = try await MCPConnectionBridge.withinTableHealthTimeout(seconds: 3_600) { () async throws -> Int in
                throw DatabaseAccessError.notFound("no such database")
            }
        } catch {
            thrown = error
        }
        let mapped = (thrown as? DatabaseAccessError).map { MCPToolExecutionError.from($0) }
        #expect(mapped?.code == .notFound)
    }

    @Test("Checks that finish within the MCP query timeout return their report")
    func checksWithinTheTimeoutReturn() async throws {
        let value = try await MCPConnectionBridge.withinTableHealthTimeout(seconds: 60) { 7 }
        #expect(value == 7)
    }

    @Test("get_table_health is a registered read-only tool taking a connection and a database")
    func toolIsReadOnlyAndRegistered() {
        #expect(GetTableHealthTool.name == "get_table_health")
        #expect(GetTableHealthTool.requiredScopes == [.toolsRead])
        #expect(GetTableHealthTool.annotations.readOnlyHint == true)
        #expect(GetTableHealthTool.annotations.destructiveHint == false)
        #expect(MCPToolRegistry.tool(named: "get_table_health") != nil)
        let inputs = keys(GetTableHealthTool.inputSchema["properties"])
        #expect(inputs == ["connection_id", "database"])
        #expect(required(GetTableHealthTool.inputSchema) == ["connection_id"])
    }

    @Test("An argument other than connection_id and database is refused before anything runs")
    func unknownArgumentIsRefused() async {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await GetTableHealthTool().call(
                arguments: .object([
                    "connection_id": .string(UUID().uuidString),
                    "schema": .string("public")
                ]),
                context: MCPToolTestHarness.context(),
                services: MCPToolTestHarness.services()
            )
        }
    }

    @Test("A call without a connection_id is refused")
    func missingConnectionIsRefused() async {
        await #expect(throws: MCPProtocolError.self) {
            _ = try await GetTableHealthTool().call(
                arguments: .object(["database": .string("shop")]),
                context: MCPToolTestHarness.context(),
                services: MCPToolTestHarness.services()
            )
        }
    }
}
