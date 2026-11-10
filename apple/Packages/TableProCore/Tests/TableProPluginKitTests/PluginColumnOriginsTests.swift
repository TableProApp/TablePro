import Foundation
import TableProPluginKit
import Testing

struct PluginColumnOriginsTests {
    private let origins: [PluginColumnOrigin?] = [PluginColumnOrigin(schema: "public", table: "users", column: "email"), nil]

    @Test("A capped stream keeps the origins its header reported")
    func boundedStreamKeepsHeaderOrigins() async throws {
        var header = PluginStreamHeader(columns: ["e", "lower"], columnTypeNames: ["text", "text"])
        header.columnOrigins = origins
        let stream = AsyncThrowingStream<PluginStreamElement, Error> { continuation in
            continuation.yield(.header(header))
            continuation.yield(.rows([[.text("a"), .text("b")], [.text("c"), .text("d")]]))
            continuation.finish()
        }

        let result = try await PluginBoundedStream.collect(stream, rowCap: 1, startedAt: Date())

        #expect(result.columnOrigins == origins)
        #expect(result.isTruncated)
    }

    @Test("Origins survive encoding, and a result without the key decodes with none")
    func codableRoundTrip() throws {
        var result = PluginQueryResult(
            columns: ["e", "lower"],
            columnTypeNames: ["text", "text"],
            rows: [],
            rowsAffected: 0,
            timing: PluginQueryTiming(total: 0)
        )
        result.columnOrigins = origins

        let decoded = try JSONDecoder().decode(PluginQueryResult.self, from: JSONEncoder().encode(result))
        #expect(decoded.columnOrigins == origins)

        let unreported = try JSONDecoder().decode(PluginQueryResult.self, from: JSONEncoder().encode(PluginQueryResult.empty))
        #expect(unreported.columnOrigins == nil)
    }
}
