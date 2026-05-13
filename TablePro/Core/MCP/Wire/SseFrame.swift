import Foundation

public struct SseFrame: Sendable, Equatable {
    public let event: String?
    public let id: String?
    public let data: String
    public let retry: Int?

    public init(event: String? = nil, id: String? = nil, data: String, retry: Int? = nil) {
        self.event = event
        self.id = id
        self.data = data
        self.retry = retry
    }
}
