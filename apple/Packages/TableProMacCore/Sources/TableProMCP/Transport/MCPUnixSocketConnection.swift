import Darwin
import Foundation

// One read runs for the channel's life and fills `buffered`; state is touched on `queue` only.
public final class MCPUnixSocketConnection: MCPByteStream, @unchecked Sendable {
    private static let readChunkSize = 65_536

    private let queue = DispatchQueue(label: "com.TablePro.MCP.UnixSocketConnection")
    private let channel: DispatchIO

    private var buffered = Data()
    private var endOfStream = false
    private var readFailure: String?
    private var pendingReceive: (maximumLength: Int, completion: @Sendable (Data?, Bool, String?) -> Void)?
    private var stateHandler: (@Sendable (MCPByteStreamState) -> Void)?
    private var started = false
    private var cancelled = false

    public init(descriptor: Int32) {
        channel = DispatchIO(type: .stream, fileDescriptor: descriptor, queue: queue) { _ in
            close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        channel.setLimit(highWater: Self.readChunkSize)
    }

    deinit {
        channel.close(flags: .stop)
    }

    public var clientAddress: MCPClientAddress {
        .localSocket
    }

    public func start(stateHandler: @escaping @Sendable (MCPByteStreamState) -> Void) {
        queue.async { [self] in
            guard !started else { return }
            started = true
            self.stateHandler = stateHandler
            guard !cancelled else {
                stateHandler(.cancelled)
                return
            }
            channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
                self?.ingest(done: done, data: data, error: error)
            }
            stateHandler(.ready)
        }
    }

    public func receive(
        maximumLength: Int,
        completion: @escaping @Sendable (Data?, _ isComplete: Bool, _ failure: String?) -> Void
    ) {
        queue.async { [self] in
            guard pendingReceive == nil else {
                completion(nil, false, "A receive is already pending")
                return
            }
            pendingReceive = (max(1, maximumLength), completion)
            deliver()
        }
    }

    public func send(_ data: Data, completion: @escaping @Sendable (_ failure: String?) -> Void) {
        queue.async { [self] in
            guard !cancelled else {
                completion("The connection is closed")
                return
            }
            let payload = data.withUnsafeBytes { DispatchData(bytes: $0) }
            channel.write(offset: 0, data: payload, queue: queue) { done, _, error in
                guard done else { return }
                completion(error == 0 ? nil : Self.describe(error))
            }
        }
    }

    public func cancel() {
        queue.async { [self] in
            guard !cancelled else { return }
            cancelled = true
            channel.close(flags: .stop)
            endOfStream = true
            deliver()
            if started {
                stateHandler?(.cancelled)
                stateHandler = nil
            }
        }
    }

    private func ingest(done: Bool, data: DispatchData?, error: Int32) {
        if let data, !data.isEmpty {
            data.enumerateBytes { bytes, _, _ in
                buffered.append(bytes)
            }
        }
        if done {
            endOfStream = true
            if error != 0, error != ECANCELED {
                readFailure = Self.describe(error)
            }
        }
        deliver()
    }

    private func deliver() {
        guard let pending = pendingReceive else { return }
        if !buffered.isEmpty {
            pendingReceive = nil
            let count = min(pending.maximumLength, buffered.count)
            let chunk = buffered.prefix(count)
            buffered = buffered.count == count ? Data() : Data(buffered.dropFirst(count))
            pending.completion(Data(chunk), false, nil)
            return
        }
        if let readFailure {
            pendingReceive = nil
            pending.completion(nil, false, readFailure)
            return
        }
        if endOfStream {
            pendingReceive = nil
            pending.completion(nil, true, nil)
        }
    }

    private static func describe(_ error: Int32) -> String {
        String(cString: strerror(error))
    }
}
