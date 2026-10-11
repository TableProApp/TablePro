import Foundation
import TableProDatabase
import TableProModels
import Testing

private struct ProducerFailure: Error, Equatable {}

private enum StreamEvent: Equatable {
    case columns([String])
    case row([String?])
    case rowsAffected(Int)
    case statusMessage(String)
    case rowCap(Int)
    case cancelled
    case memoryPressure
    case driverLimit
}

private func collect(_ stream: AsyncThrowingStream<StreamElement, Error>) async throws -> [StreamEvent] {
    var events: [StreamEvent] = []
    for try await element in stream {
        events.append(event(for: element))
    }
    return events
}

private func event(for element: StreamElement) -> StreamEvent {
    switch element {
    case .columns(let columns):
        return .columns(columns.map(\.name))
    case .row(let row):
        return .row(row.legacyValues)
    case .rowsAffected(let count):
        return .rowsAffected(count)
    case .statusMessage(let message):
        return .statusMessage(message)
    case .truncated(let reason):
        switch reason {
        case .rowCap(let cap): return .rowCap(cap)
        case .cancelled: return .cancelled
        case .memoryPressure: return .memoryPressure
        case .driverLimit: return .driverLimit
        }
    }
}

private let valueColumn = [ColumnInfo(name: "value", typeName: "string", ordinalPosition: 0)]

@Suite("QueryResultStreaming")
struct QueryResultStreamingTests {
    @Test("the columns come first, then one element per row")
    func streamsColumnsThenRows() async throws {
        let result = QueryResult(columns: valueColumn, rows: [["a"], ["b"]], rowsAffected: 0, executionTime: 0)
        let events = try await collect(QueryResultStreaming.stream(options: .default) { result })
        #expect(events == [.columns(["value"]), .row(["a"]), .row(["b"])])
    }

    @Test("rows past the cap are cut and the cut is reported")
    func rowCapTruncates() async throws {
        let result = QueryResult(columns: valueColumn, rows: [["a"], ["b"], ["c"]], rowsAffected: 0, executionTime: 0)
        let options = StreamOptions(maxRows: 2)
        let events = try await collect(QueryResultStreaming.stream(options: options) { result })
        #expect(events == [.columns(["value"]), .row(["a"]), .row(["b"]), .rowCap(2)])
    }

    @Test("a status message and an affected count follow the rows")
    func statusAndRowsAffected() async throws {
        let result = QueryResult(
            columns: [],
            rows: [],
            rowsAffected: 3,
            executionTime: 0,
            statusMessage: "OK"
        )
        let events = try await collect(QueryResultStreaming.stream(options: .default) { result })
        #expect(events == [.columns([]), .statusMessage("OK"), .rowsAffected(3)])
    }

    @Test("a result the producer marked truncated says so")
    func producerTruncation() async throws {
        let result = QueryResult(columns: valueColumn, rows: [["a"]], rowsAffected: 0, executionTime: 0, isTruncated: true)
        let events = try await collect(QueryResultStreaming.stream(options: .default) { result })
        #expect(events == [.columns(["value"]), .row(["a"]), .driverLimit])
    }

    @Test("a producer that throws finishes the stream with its error")
    func producerErrorFinishesTheStream() async {
        let stream = QueryResultStreaming.stream(options: .default) { () async throws -> QueryResult in
            throw ProducerFailure()
        }
        await #expect(throws: ProducerFailure()) {
            _ = try await collect(stream)
        }
    }

    @Test("a producer that is cancelled ends the stream as cancelled")
    func producerCancellationEndsAsCancelled() async throws {
        let stream = QueryResultStreaming.stream(options: .default) { () async throws -> QueryResult in
            throw CancellationError()
        }
        let events = try await collect(stream)
        #expect(events == [.cancelled])
    }
}
