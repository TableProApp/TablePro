import Foundation

actor MCPSseWriter {
    static let keepAliveInterval: Duration = .seconds(15)

    private let emit: @Sendable (Data) async -> Void
    private let isAlive: @Sendable () async -> Bool
    private var keepAliveTask: Task<Void, Never>?
    private var stopped = false

    init(
        emit: @escaping @Sendable (Data) async -> Void,
        isAlive: @escaping @Sendable () async -> Bool
    ) {
        self.emit = emit
        self.isAlive = isAlive
    }

    func start() {
        guard keepAliveTask == nil, !stopped else { return }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled, let self else { return }
                await self.emitKeepAlive()
            }
        }
    }

    func writeFrame(_ frame: SseFrame) async {
        guard !stopped else { return }
        await emit(SseEncoder.encode(frame))
    }

    func writeComment(_ text: String) async {
        guard !stopped else { return }
        await emit(Self.commentPayload(text))
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    private func emitKeepAlive() async {
        guard !stopped else { return }
        guard await isAlive() else {
            stop()
            return
        }
        await emit(Self.commentPayload(""))
    }

    private static func commentPayload(_ text: String) -> Data {
        text.isEmpty ? Data(":\r\n".utf8) : Data(": \(text)\r\n".utf8)
    }
}
