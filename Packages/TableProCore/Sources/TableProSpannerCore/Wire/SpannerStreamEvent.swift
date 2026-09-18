import Foundation

public enum SpannerStreamEvent: Sendable {
    case metadata(SpannerResultSetMetadata)
    case rows([[SpannerJSONValue]])
    case stats(SpannerResultSetStats)
}

public struct SpannerOperation: Sendable, Equatable {
    public let name: String
    public let done: Bool
    public let error: SpannerAPIError?

    public init(name: String, done: Bool, error: SpannerAPIError?) {
        self.name = name
        self.done = done
        self.error = error
    }
}

internal struct SpannerStreamDecoder: Sendable {
    private let httpStatus: Int
    private var framer = SpannerStreamFramer()
    private var assembler = SpannerPartialResultAssembler()
    private var didEmitMetadata = false

    init(httpStatus: Int) {
        self.httpStatus = httpStatus
    }

    mutating func consume(_ chunk: Data) throws -> [SpannerStreamEvent] {
        var events: [SpannerStreamEvent] = []
        for frame in try framer.append(chunk) {
            switch try SpannerStreamMessage.decode(frame, httpStatus: httpStatus) {
            case .failure(let error):
                throw error
            case .partial(let partial):
                let rows = try assembler.consume(partial)
                appendMetadataIfNew(to: &events)
                if !rows.isEmpty {
                    events.append(.rows(rows))
                }
            }
        }
        return events
    }

    mutating func finish() throws -> [SpannerStreamEvent] {
        try framer.finish()
        try assembler.finish()
        var events: [SpannerStreamEvent] = []
        appendMetadataIfNew(to: &events)
        if let stats = assembler.stats {
            events.append(.stats(stats))
        }
        return events
    }

    private mutating func appendMetadataIfNew(to events: inout [SpannerStreamEvent]) {
        guard !didEmitMetadata, let metadata = assembler.metadata else { return }
        didEmitMetadata = true
        events.append(.metadata(metadata))
    }
}
