import Foundation
import TableProModels

public enum QueryResultStreaming {
    public static func stream(
        options: StreamOptions,
        producing produce: @escaping @Sendable () async throws -> QueryResult
    ) -> AsyncThrowingStream<StreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await produce()
                    emit(result, options: options, into: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.truncated(reason: .cancelled))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func emit(
        _ result: QueryResult,
        options: StreamOptions,
        into continuation: AsyncThrowingStream<StreamElement, Error>.Continuation
    ) {
        continuation.yield(.columns(result.columns))

        var emitted = 0
        for legacyRow in result.rows {
            if Task.isCancelled {
                continuation.yield(.truncated(reason: .cancelled))
                break
            }
            if emitted >= options.maxRows {
                continuation.yield(.truncated(reason: .rowCap(options.maxRows)))
                break
            }
            let cells = legacyRow.enumerated().map { index, value -> Cell in
                let typeName = index < result.columns.count ? result.columns[index].typeName : nil
                return Cell.from(legacyValue: value, columnTypeName: typeName, options: options)
            }
            continuation.yield(.row(Row(cells: cells)))
            emitted += 1
        }

        if let message = result.statusMessage {
            continuation.yield(.statusMessage(message))
        }
        if result.rowsAffected != 0 {
            continuation.yield(.rowsAffected(result.rowsAffected))
        }
        if result.isTruncated && emitted < options.maxRows {
            continuation.yield(.truncated(reason: .driverLimit("driver returned isTruncated=true")))
        }
    }
}
