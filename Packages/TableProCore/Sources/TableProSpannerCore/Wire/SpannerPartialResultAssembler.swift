import Foundation

public struct SpannerPartialResultAssembler: Sendable {
    public private(set) var metadata: SpannerResultSetMetadata?
    public private(set) var stats: SpannerResultSetStats?
    private var pendingChunk: SpannerJSONValue?
    private var bufferedValues: [SpannerJSONValue] = []

    public init() {}

    public mutating func consume(_ partial: SpannerPartialResultSet) throws -> [[SpannerJSONValue]] {
        if metadata == nil, let incoming = partial.metadata {
            metadata = incoming
        }
        if let incoming = partial.stats {
            stats = incoming
        }
        var values = partial.values
        if let pending = pendingChunk, !values.isEmpty {
            values[0] = try Self.merge(pending, values[0])
            pendingChunk = nil
        }
        if partial.chunkedValue {
            guard pendingChunk == nil, let last = values.popLast() else {
                throw SpannerTransportError.invalidResponse
            }
            pendingChunk = last
        }
        bufferedValues.append(contentsOf: values)
        return takeCompleteRows()
    }

    public func finish() throws {
        guard pendingChunk == nil, bufferedValues.isEmpty else {
            throw SpannerTransportError.invalidResponse
        }
    }

    private mutating func takeCompleteRows() -> [[SpannerJSONValue]] {
        let width = metadata?.fields.count ?? 0
        guard width > 0, bufferedValues.count >= width else { return [] }
        let completeCount = bufferedValues.count - bufferedValues.count % width
        let rows = stride(from: 0, to: completeCount, by: width).map { start in
            Array(bufferedValues[start..<(start + width)])
        }
        bufferedValues.removeFirst(completeCount)
        return rows
    }

    static func merge(_ head: SpannerJSONValue, _ tail: SpannerJSONValue) throws -> SpannerJSONValue {
        switch (head, tail) {
        case (.string(let first), .string(let second)):
            return .string(first + second)
        case (.list(let first), .list(let second)):
            return .list(try mergeLists(first, second))
        default:
            throw SpannerTransportError.invalidResponse
        }
    }

    private static func mergeLists(_ first: [SpannerJSONValue], _ second: [SpannerJSONValue]) throws -> [SpannerJSONValue] {
        guard let last = first.last, let next = second.first, isChunkable(last, next) else {
            return first + second
        }
        var merged = Array(first.dropLast())
        merged.append(try merge(last, next))
        merged.append(contentsOf: second.dropFirst())
        return merged
    }

    private static func isChunkable(_ head: SpannerJSONValue, _ tail: SpannerJSONValue) -> Bool {
        switch (head, tail) {
        case (.string, .string), (.list, .list):
            return true
        default:
            return false
        }
    }
}
