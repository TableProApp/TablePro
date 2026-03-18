import Foundation

public enum PluginCapability: Int, Codable, Sendable {
    case databaseDriver
    case exportFormat
    case importFormat
}
