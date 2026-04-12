import Foundation

public struct PluginRoutineInfo: Codable, Sendable {
    public let name: String
    public let type: String

    public init(name: String, type: String = "PROCEDURE") {
        self.name = name
        self.type = type
    }
}
