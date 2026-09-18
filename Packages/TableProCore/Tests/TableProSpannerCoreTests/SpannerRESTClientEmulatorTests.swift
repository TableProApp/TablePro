import Foundation
import Testing

@testable import TableProSpannerCore

@Suite(
    "SpannerRESTClient against the emulator",
    .enabled(if: SpannerEmulatorEnvironment.host != nil),
    .serialized
)
struct SpannerRESTClientEmulatorTests {
    private static func environment(_ key: String, default fallback: String) -> String {
        SpannerEmulatorEnvironment.value(key) ?? fallback
    }

    private func makeClient() throws -> (SpannerRESTClient, URLSessionSpannerTransport) {
        let settings = try SpannerConnectionSettings.parse(fields: [
            SpannerConnectionSettings.FieldKey.projectId: Self.environment("SPANNER_EMULATOR_PROJECT", default: "proj"),
            SpannerConnectionSettings.FieldKey.instanceId: Self.environment("SPANNER_EMULATOR_INSTANCE", default: "inst"),
            SpannerConnectionSettings.FieldKey.databaseId: Self.environment("SPANNER_EMULATOR_DATABASE", default: "gdb"),
            SpannerConnectionSettings.FieldKey.endpoint: SpannerEmulatorEnvironment.host ?? "",
            SpannerConnectionSettings.FieldKey.authMethod: SpannerAuthMethod.emulator.rawValue
        ])
        let transport = URLSessionSpannerTransport(requestTimeout: { 30 })
        return (SpannerRESTClient(settings: settings, transport: transport, tokenProvider: nil), transport)
    }

    @Test("Session, executeSql, streaming and teardown work on the real wire")
    func smoke() async throws {
        let (client, _) = try makeClient()
        #expect(try await client.databaseDialect() == "GOOGLE_STANDARD_SQL")

        let session = try await client.createSession(multiplexed: false)
        #expect(session.contains("/sessions/"))

        let single = try await client.executeSql(
            session: session,
            SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
        )
        let fields = try #require(single.metadata?.fields)
        #expect(fields.map(\.name) == [""])
        #expect(SpannerValueDecoder.rows(single.rows, fields: fields) == [[.text("1")]])

        let planned = try await client.executeSql(
            session: session,
            SpannerExecuteSqlRequest(sql: "SELECT @p1 + 1 AS x", transaction: .singleUseStrongReadOnly, queryMode: .plan)
        )
        #expect(planned.metadata?.undeclaredParameters == [SpannerField(name: "p1", type: SpannerType(code: "INT64"))])

        let bound = try await client.executeSql(
            session: session,
            SpannerExecuteSqlRequest(
                sql: "SELECT @p1 + 1 AS x, @p2 AS flag, @p3 AS list",
                transaction: .singleUseStrongReadOnly,
                params: [
                    "p1": try SpannerParameterEncoder.encode(.text("41"), as: SpannerType(code: "INT64"), index: 1),
                    "p2": try SpannerParameterEncoder.encode(.text("TRUE"), as: SpannerType(code: "BOOL"), index: 2),
                    "p3": try SpannerParameterEncoder.encode(
                        .text("[1.5, \"NaN\"]"),
                        as: SpannerType(code: "ARRAY", arrayElementType: SpannerType(code: "FLOAT64")),
                        index: 3
                    )
                ],
                paramTypes: [
                    "p1": SpannerType(code: "INT64"),
                    "p2": SpannerType(code: "BOOL"),
                    "p3": SpannerType(code: "ARRAY", arrayElementType: SpannerType(code: "FLOAT64"))
                ]
            )
        )
        let boundFields = try #require(bound.metadata?.fields)
        #expect(SpannerValueDecoder.rows(bound.rows, fields: boundFields) == [[.text("42"), .text("true"), .text(#"[1.5,"NaN"]"#)]])

        let stream = try await client.executeStreamingSql(
            session: session,
            SpannerExecuteSqlRequest(
                sql: "SELECT n AS id, 'r' || CAST(n AS STRING) AS label FROM UNNEST(GENERATE_ARRAY(1, 2500)) AS n ORDER BY n",
                transaction: .singleUseStrongReadOnly
            )
        )
        let events = try await collectEvents(stream)
        let rows = streamedRows(events)
        #expect(rows.count == 2_500)
        #expect(rows.first == [.string("1"), .string("r1")])
        #expect(rows.last == [.string("2500"), .string("r2500")])

        try await client.deleteSession(session)
        do {
            _ = try await client.executeSql(
                session: session,
                SpannerExecuteSqlRequest(sql: "SELECT 1", transaction: .singleUseStrongReadOnly)
            )
            Issue.record("A deleted session must be reported as not found")
        } catch let error as SpannerAPIError {
            #expect(error.isSessionNotFound)
        }
        await client.close()
    }

    @Test("A stream whose values are chunked across messages reassembles on the real wire")
    func chunkedStream() async throws {
        let (client, _) = try makeClient()
        let session = try await client.createSession(multiplexed: false)
        let sql = """
        SELECT 1 AS id, [REPEAT('a', 900000), REPEAT('b', 900000), REPEAT('c', 900000)] AS arr, \
        REPEAT('z', 900000) AS s2, 7 AS tail
        """
        let stream = try await client.executeStreamingSql(
            session: session,
            SpannerExecuteSqlRequest(sql: sql, transaction: .singleUseStrongReadOnly)
        )
        let rows = streamedRows(try await collectEvents(stream))
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.count == 4)
        guard case .list(let elements) = row[1], case .string(let tail) = row[2] else {
            Issue.record("Unexpected shapes for the chunked columns")
            return
        }
        let lengths = elements.map { element -> Int in
            guard case .string(let text) = element else { return -1 }
            return (text as NSString).length
        }
        #expect(lengths == [900_000, 900_000, 900_000])
        #expect(elements.map { element -> Bool in
            guard case .string(let text) = element, let first = text.first else { return false }
            return text.allSatisfy { $0 == first }
        } == [true, true, true])
        #expect((tail as NSString).length == 900_000)
        #expect(row[3] == .string("7"))
        try await client.deleteSession(session)
        await client.close()
    }

    @Test("The emulator's in-stream error decodes to its gRPC code")
    func streamError() async throws {
        let (client, _) = try makeClient()
        let session = try await client.createSession(multiplexed: false)
        do {
            let stream = try await client.executeStreamingSql(
                session: session,
                SpannerExecuteSqlRequest(sql: "SELECT 1/0", transaction: .singleUseStrongReadOnly)
            )
            _ = try await collectEvents(stream)
            Issue.record("Division by zero must fail")
        } catch let error as SpannerAPIError {
            #expect(error.message.contains("division by zero"))
        }
        try await client.deleteSession(session)
        await client.close()
    }

    @Test("A closed transport refuses new requests")
    func closedTransport() async throws {
        let (client, _) = try makeClient()
        await client.close()
        await #expect(throws: SpannerTransportError.closed) {
            try await client.createSession(multiplexed: false)
        }
    }
}
