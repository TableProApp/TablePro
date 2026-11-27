import Foundation

// The schema-wide reads that answer each table exactly as its own read does, so an export can take one in place of a
// read per table.
public struct PluginExportBulkReads: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let columns = PluginExportBulkReads(rawValue: 1 << 0)
    public static let foreignKeys = PluginExportBulkReads(rawValue: 1 << 1)
    public static let indexes = PluginExportBulkReads(rawValue: 1 << 2)
    public static let indexDDL = PluginExportBulkReads(rawValue: 1 << 3)
    public static let commentDDL = PluginExportBulkReads(rawValue: 1 << 4)
    public static let dependentSequences = PluginExportBulkReads(rawValue: 1 << 5)
    public static let dependentTypes = PluginExportBulkReads(rawValue: 1 << 6)
    public static let tableDDL = PluginExportBulkReads(rawValue: 1 << 7)
}
