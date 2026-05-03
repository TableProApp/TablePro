import Foundation

public actor MCPStdioMessageTransport: MCPMessageTransport {
    nonisolated public let inbound: AsyncThrowingStream<JsonRpcMessage, Error>
    nonisolated private let continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation

    private let writer: StdioWriter
    private let errorLogger: (any MCPBridgeLogger)?
    private var readerTask: Task<Void, Never>?
    private var isClosed = false

    public init(
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        errorLogger: (any MCPBridgeLogger)? = nil
    ) {
        let (stream, continuation) = AsyncThrowingStream<JsonRpcMessage, Error>.makeStream()
        self.inbound = stream
        self.continuation = continuation
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
        continuation.finish()
    }

    private func startReader(stdin: FileHandle) {
        if isClosed {
            return
        }
        let continuation = self.continuation
        let logger = errorLogger
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.readLoop(stdin: stdin, continuation: continuation, logger: logger)
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
        continuation.finish()
    }

    private static func readLoop(
        stdin: FileHandle,
        continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation,
        logger: (any MCPBridgeLogger)?
    ) async {
        var buffer = Data()
        do {
            for try await byte in stdin.bytes {
                if Task.isCancelled {
                    return
                }
                if byte == 0x0A {
                    processLine(buffer, continuation: continuation, logger: logger)
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                buffer.append(byte)
            }
        } catch {
            logger?.log(.error, "stdio read failed: \(error)")
            continuation.finish(throwing: MCPTransportError.readFailed(detail: String(describing: error)))
            return
        }

        if !buffer.isEmpty {
            processLine(buffer, continuation: continuation, logger: logger)
        }
    }

    private static func processLine(
        _ raw: Data,
        continuation: AsyncThrowingStream<JsonRpcMessage, Error>.Continuation,
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
            continuation.yield(message)
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
