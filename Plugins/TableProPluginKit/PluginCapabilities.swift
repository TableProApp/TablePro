import Foundation

public struct PluginCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let materializedViews     = PluginCapabilities(rawValue: 1 << 0)
    public static let foreignTables         = PluginCapabilities(rawValue: 1 << 1)
    public static let storedProcedures      = PluginCapabilities(rawValue: 1 << 2)
    public static let userFunctions         = PluginCapabilities(rawValue: 1 << 3)
    public static let alterTableDDL         = PluginCapabilities(rawValue: 1 << 4)
    public static let foreignKeyToggle      = PluginCapabilities(rawValue: 1 << 5)
    public static let truncateTable         = PluginCapabilities(rawValue: 1 << 6)
    public static let multiSchema           = PluginCapabilities(rawValue: 1 << 7)
    public static let parameterizedQueries  = PluginCapabilities(rawValue: 1 << 8)
    public static let cancelQuery           = PluginCapabilities(rawValue: 1 << 9)
    public static let batchExecute          = PluginCapabilities(rawValue: 1 << 10)
    public static let transactions          = PluginCapabilities(rawValue: 1 << 11)
}
