import Foundation

public struct ConnectionPrompt: Sendable, Identifiable, Equatable {
    public enum Style: Sendable, Equatable {
        case standard
        case destructive
        case notice
    }

    public let id: UUID
    public let title: String
    public let message: String
    public let confirmTitle: String
    public let style: Style

    public init(
        id: UUID = UUID(),
        title: String,
        message: String,
        confirmTitle: String,
        style: Style = .standard
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.style = style
    }
}

public protocol ConnectionPrompter: Sendable {
    @MainActor
    func confirm(_ prompt: ConnectionPrompt) async -> Bool
}
