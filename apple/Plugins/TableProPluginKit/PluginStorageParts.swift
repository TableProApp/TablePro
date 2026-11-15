import Foundation

// The parts a table's rows are stored in, for an engine that writes a table as merged parts grouped by partition.
// Every statement names its own database: the session's can move under it.
public protocol PluginStorageParts: AnyObject, Sendable {
    func fetchStorageParts(table: String, database: String) async throws -> [PluginStoragePart]
    // Nil where the engine cannot express it; a partition id the engine would not accept is one.
    func mergePartsStatement(table: String, database: String) -> String?
    func dropPartitionStatement(table: String, database: String, partitionId: String) -> String?
    func detachPartitionStatement(table: String, database: String, partitionId: String) -> String?
}

public struct PluginStoragePart: Sendable, Hashable {
    public let partition: String
    public let partitionId: String
    public let name: String
    public let rows: UInt64
    public let bytesOnDisk: UInt64
    public let modificationTime: String
    public let isActive: Bool

    public init(
        partition: String,
        partitionId: String,
        name: String,
        rows: UInt64,
        bytesOnDisk: UInt64,
        modificationTime: String,
        isActive: Bool
    ) {
        self.partition = partition
        self.partitionId = partitionId
        self.name = name
        self.rows = rows
        self.bytesOnDisk = bytesOnDisk
        self.modificationTime = modificationTime
        self.isActive = isActive
    }
}
