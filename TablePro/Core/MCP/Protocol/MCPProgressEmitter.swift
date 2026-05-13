import Foundation

public protocol MCPProgressSink: Sendable {
    func sendNotification(_ notification: JsonRpcNotification, toSession sessionId: MCPSessionId) async
}

public actor MCPProgressEmitter {
    private let progressToken: JsonValue?
    private let target: any MCPProgressSink
    private let sessionId: MCPSessionId

    public init(progressToken: JsonValue?, target: any MCPProgressSink, sessionId: MCPSessionId) {
        self.progressToken = progressToken
        self.target = target
        self.sessionId = sessionId
    }

    public func emit(progress: Double, total: Double? = nil, message: String? = nil) async {
        guard let progressToken else { return }

        var params: [String: JsonValue] = [
            "progressToken": progressToken,
            "progress": .double(progress)
        ]
        if let total {
            params["total"] = .double(total)
        }
        if let message {
            params["message"] = .string(message)
        }

        let notification = JsonRpcNotification(
            method: "notifications/progress",
            params: .object(params)
        )
        await target.sendNotification(notification, toSession: sessionId)
    }

    public func emitNotification(method: String, params: JsonValue?) async {
        let notification = JsonRpcNotification(method: method, params: params)
        await target.sendNotification(notification, toSession: sessionId)
    }

    public var hasProgressToken: Bool {
        progressToken != nil
    }

    public static func extractProgressToken(from params: JsonValue?) -> JsonValue? {
        guard let meta = params?["_meta"] else { return nil }
        return meta["progressToken"]
    }
}
