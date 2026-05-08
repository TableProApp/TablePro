import Foundation
import os

actor MCPSseWriter {
    static let keepAliveInterval: Duration = .seconds(30)

    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.SseWriter")

    private let context: HttpConnectionContext
    private var keepAliveTask: Task<Void, Never>?
    private var stopped = false

    init(context: HttpConnectionContext) {
        self.context = context
    }

    func startStream(sessionId: MCPSessionId) async {
        await context.writeSseStreamHeaders(sessionId: sessionId)
        startKeepAlive()
    }

    func writeFrame(_ frame: SseFrame) async {
        guard !stopped else { return }
        await context.writeSseFrame(frame)
    }

    func writeComment(_ text: String) async {
        guard !stopped else { return }
        await context.writeRaw(Data("\u{003A} \(text)\n\n".utf8))
    }

    func stop() async {
        if stopped { return }
        stopped = true
        keepAliveTask?.cancel()
        keepAliveTask = nil
        await context.cancel()
    }

    private func startKeepAlive() {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.keepAliveInterval)
                guard !Task.isCancelled, let self else { return }
                await self.emitKeepAlive()
            }
        }
    }

    private func emitKeepAlive() async {
        guard !stopped else { return }
        if await context.isCancelled() {
            keepAliveTask?.cancel()
            keepAliveTask = nil
            stopped = true
            return
        }
        await context.writeRaw(Data("\u{003A} keep-alive\n\n".utf8))
    }
}
