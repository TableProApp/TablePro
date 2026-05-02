import Foundation

public actor MCPStdioMessageTransport: MCPMessageTransport {
    nonisolated public let inbound: AsyncThrowingStream<JsonRpcMessage, Error>

    nonisolated private let continuationBox: StreamContinuationBox
    private let writer: StdioWriter
    private let errorLogger: (any MCPBridgeLogger)?
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        let box = StreamContinuationBox()
        let stream = AsyncThrowingStream<JsonRpcMessage, Error> { continuation in
            box.set(continuation)
        }
        self.continuationBox = box
        self.inbound = stream
        self.writer = StdioWriter(handle: stdout)
        self.errorLogger = errorLogger

        Task { await self.startReader(stdin: stdin) }
    }

    public func send(_ message: JsonRpcMessage) async throws {
        if isClosed {
            throw MCPTransportError.closed
        }

        let line: Data
        do {
            line = try JsonRpcCodec.encodeLine(message)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }

        do {
            try await writer.write(line)
        } catch {
            throw MCPTransportError.writeFailed(detail: String(describing: error))
        }
    }

    public func close() async {
        if isClosed {
            return
        }
        isClosed = true
        let task = readerTask
        readerTask = nil
        task?.cancel()
        continuationBox.finish()
    }

    private func startReader(stdin: FileHandle) {
        if isClosed {
            return
        }
        let box = continuationBox
        let logger = errorLogger
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.readLoop(stdin: stdin, box: box, logger: logger)
            await self?.finishStream()
        }
        readerTask = task
    }

    private func finishStream() {
        if isClosed {
            return
        }
        isClosed = true
        readerTask = nil
        continuationBox.finish()
    }

    private static func readLoop(
        stdin: FileHandle,
        box: StreamContinuationBox,
        logger: (any MCPBridgeLogger)?
    ) async {
        var buffer = Data()
        do {
            for try await byte in stdin.bytes {
                if Task.isCancelled {
                    return
                }
                if byte == 0x0A {
                    processLine(buffer, box: box, logger: logger)
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                buffer.append(byte)
            }
        } catch {
            logger?.log(.error, "stdio read failed: \(error)")
            box.finish(throwing: MCPTransportError.readFailed(detail: String(describing: error)))
            return
        }

        if !buffer.isEmpty {
            processLine(buffer, box: box, logger: logger)
        }
    }

    private static func processLine(
        _ raw: Data,
        box: StreamContinuationBox,
        logger: (any MCPBridgeLogger)?
    ) {
        var trimmed = raw
        if trimmed.last == 0x0D {
            trimmed.removeLast()
        }
        if trimmed.isEmpty {
            return
        }

        do {
            let message = try JsonRpcCodec.decode(trimmed)
            box.yield(message)
        } catch {
            logger?.log(.warning, "stdio: skipping malformed JSON-RPC line: \(error)")
        }
    }
}

private actor StdioWriter {
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        try? handle.synchronize()
    }
}

final class StreamContinuationBox: Sendable {
    nonisolated(unsafe) private var continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation?
    private let lock = NSLock()

    func set(_ continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation) {
        lock.withLock {
            self.continuation = continuation
        }
    }

    func yield(_ message: JsonRpcMessage) {
        lock.withLock {
            continuation?.yield(message)
        }
    }

    func finish(throwing error: Error? = nil) {
        lock.withLock {
            if let error {
                continuation?.finish(throwing: error)
            } else {
                continuation?.finish()
            }
            continuation = nil
        }
    }
}
