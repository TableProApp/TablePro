import Foundation
import os

public actor MCPProgressEmitter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "MCP.Progress")
    private static let notificationMethod = "notifications/progress"

    private let progressToken: MCPProgressToken?
    private let responder: MCPResponder
    private var lastProgress: Double?

    public init(progressToken: MCPProgressToken?, responder: MCPResponder) {
        self.progressToken = progressToken
        self.responder = responder
    }

    public init(meta: MCPRequestMeta, responder: MCPResponder) {
        progressToken = meta.progressToken
        self.responder = responder
    }

    public var hasProgressToken: Bool {
        progressToken != nil
    }

    public func emit(progress: Double, total: Double? = nil, message: String? = nil) async {
        guard let progressToken, progress.isFinite else { return }
        if let lastProgress, progress <= lastProgress {
            Self.logger.debug("Dropping progress update that does not advance")
            return
        }
        lastProgress = progress

        var params: [String: JsonValue] = [
            "progressToken": progressToken.asJsonValue,
            "progress": .double(progress)
        ]
        if let total, total.isFinite {
            params["total"] = .double(total)
        }
        if let message, !message.isEmpty {
            params["message"] = .string(message)
        }

        let notification = JsonRpcNotification(method: Self.notificationMethod, params: .object(params))
        await responder.emit(.notification(notification))
    }
}
