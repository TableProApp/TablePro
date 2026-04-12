import Foundation

public struct PluginRoutineParameterInfo: Codable, Sendable {
    public let name: String?
    public let dataType: String
    public let direction: String
    public let ordinalPosition: Int
    public let defaultValue: String?

    public init(name: String?, dataType: String, direction: String = "IN",
                ordinalPosition: Int, defaultValue: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.direction = direction
        self.ordinalPosition = ordinalPosition
        self.defaultValue = defaultValue
    }
}
