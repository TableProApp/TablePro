import Foundation

public struct PluginExportTable: Sendable {
    public let name: String
    public let databaseName: String
    public let tableType: String
    public let optionValues: [Bool]

    public init(name: String, databaseName: String, tableType: String, optionValues: [Bool] = []) {
        self.name = name
        self.databaseName = databaseName
        self.tableType = tableType
        self.optionValues = optionValues
    }

    public var qualifiedName: String {
        databaseName.isEmpty ? name : "\(databaseName).\(name)"
    }
}

public struct PluginExportOptionColumn: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let width: Double
    public let defaultValue: Bool

    public init(id: String, label: String, width: Double, defaultValue: Bool = true) {
        self.id = id
        self.label = label
        self.width = width
        self.defaultValue = defaultValue
    }
}

public enum PluginExportError: LocalizedError {
    case fileWriteFailed(String)
    case encodingFailed
    case compressionFailed
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileWriteFailed(let path):
            return "Failed to write file: \(path)"
        case .encodingFailed:
            return "Failed to encode content as UTF-8"
        case .compressionFailed:
            return "Failed to compress data"
        case .exportFailed(let message):
            return "Export failed: \(message)"
        }
    }
}

public struct PluginExportCancellationError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Export cancelled" }
}

public struct PluginSequenceInfo: Sendable {
    public let name: String
    public let ddl: String

    public init(name: String, ddl: String) {
        self.name = name
        self.ddl = ddl
    }
}

public struct PluginEnumTypeInfo: Sendable {
    public let name: String
    public let labels: [String]

    public init(name: String, labels: [String]) {
        self.name = name
        self.labels = labels
    }
}

public typealias PluginRow = [String?]

public struct PluginStreamHeader: Sendable {
    public let columns: [String]
    public let columnTypeNames: [String]
    public let estimatedRowCount: Int?

    public init(columns: [String], columnTypeNames: [String], estimatedRowCount: Int? = nil) {
        self.columns = columns
        self.columnTypeNames = columnTypeNames
        self.estimatedRowCount = estimatedRowCount
    }
}

public enum PluginStreamElement: Sendable {
    case header(PluginStreamHeader)
    case rows([PluginRow])
}

public struct ExportFormatResult: Sendable {
    public let warnings: [String]
    public init(warnings: [String] = []) {
        self.warnings = warnings
    }
}

public protocol PluginExportDataSource: AnyObject, Sendable {
    var databaseTypeId: String { get }
    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error>
    func fetchTableDDL(table: String, databaseName: String) async throws -> String
    func execute(query: String) async throws -> PluginQueryResult
    func quoteIdentifier(_ identifier: String) -> String
    func escapeStringLiteral(_ value: String) -> String
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int?
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo]
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo]
}

public extension PluginExportDataSource {
    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] { [] }
    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] { [] }
}

public final class PluginExportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 1_000
    private var internalRowCount: Int = 0
    private let lock = NSLock()

    public init(progress: Progress) {
        self.progress = progress
    }

    public func setCurrentTable(_ name: String, index: Int) {
        progress.localizedDescription = name
    }

    public func incrementRow() {
        lock.lock()
        internalRowCount += 1
        let count = internalRowCount
        let shouldNotify = count % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            progress.completedUnitCount = Int64(count)
        }
    }

    public func finalizeTable() {
        lock.lock()
        let count = internalRowCount
        lock.unlock()
        progress.completedUnitCount = Int64(count)
    }

    public func setStatus(_ message: String) {
        progress.localizedAdditionalDescription = message
    }

    public func checkCancellation() throws {
        if progress.isCancelled || Task.isCancelled {
            throw PluginExportCancellationError()
        }
    }

    public func cancel() {
        progress.cancel()
    }

    public var isCancelled: Bool {
        progress.isCancelled || Task.isCancelled
    }

    public var processedRows: Int {
        lock.lock()
        defer { lock.unlock() }
        return internalRowCount
    }

    public var totalRows: Int {
        Int(progress.totalUnitCount)
    }

}

public protocol ExportFormatPlugin: TableProPlugin {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var defaultFileExtension: String { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }

    static var perTableOptionColumns: [PluginExportOptionColumn] { get }
    func defaultTableOptionValues() -> [Bool]
    func isTableExportable(optionValues: [Bool]) -> Bool

    var currentFileExtension: String { get }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult
}

public extension ExportFormatPlugin {
    static var capabilities: [PluginCapability] { [.exportFormat] }
    static var supportedDatabaseTypeIds: [String] { [] }
    static var excludedDatabaseTypeIds: [String] { [] }
    static var perTableOptionColumns: [PluginExportOptionColumn] { [] }
    func defaultTableOptionValues() -> [Bool] { [] }
    func isTableExportable(optionValues: [Bool]) -> Bool { true }
    var currentFileExtension: String { Self.defaultFileExtension }
}
