import Foundation

public struct MCPInputRequired: Error, Sendable, Equatable {
    public let inputRequests: [MCPElicitationRequest]
    public let requestState: String?

    public init(inputRequests: [MCPElicitationRequest], requestState: String?) {
        self.inputRequests = inputRequests
        self.requestState = requestState
    }

    public var isValid: Bool {
        !inputRequests.isEmpty || requestState != nil
    }

    public var asResult: MCPResult {
        var payload: [String: JsonValue] = [:]
        if !inputRequests.isEmpty {
            var requests: [String: JsonValue] = [:]
            for request in inputRequests {
                requests[request.key] = request.asJsonValue
            }
            payload["inputRequests"] = .object(requests)
        }
        if let requestState {
            payload["requestState"] = .string(requestState)
        }
        return MCPResult(kind: .inputRequired, payload: payload, cacheHint: nil)
    }
}
