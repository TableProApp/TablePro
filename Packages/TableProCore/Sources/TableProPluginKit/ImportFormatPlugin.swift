import Foundation

public enum ImportErrorHandling: String, Codable, CaseIterable, Sendable {
    case stopAndRollback
    case stopAndCommit
    case skipAndContinue
}

public struct PluginImportResult: Sendable {
    public let executedStatements: Int
    public let skippedStatements: Int
    public let executionTime: TimeInterval
    public let errors: [ImportStatementError]

    public init(
        executedStatements: Int,
        executionTime: TimeInterval,
        skippedStatements: Int = 0,
        errors: [ImportStatementError] = []
    ) {
        self.executedStatements = executedStatements
        self.skippedStatements = skippedStatements
        self.executionTime = executionTime
        self.errors = errors
    }
}

public extension PluginImportResult {
    struct ImportStatementError: Sendable {
        public let statement: String
        public let line: Int
        public let errorMessage: String

        public init(statement: String, line: Int, errorMessage: String) {
            self.statement = statement
            self.line = line
            self.errorMessage = errorMessage
        }
    }
}

public enum PluginImportError: LocalizedError {
    case statementFailed(statement: String, line: Int, underlyingError: any Error)
    case rollbackFailed(underlyingError: any Error)
    case cancelled
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .statementFailed(_, let line, let error):
            return "Import failed at line \(line): \(error.localizedDescription)"
        case .rollbackFailed(let error):
            return "Transaction rollback failed: \(error.localizedDescription)"
        case .cancelled:
            return "Import cancelled"
        case .importFailed(let message):
            return "Import failed: \(message)"
        }
    }
}

public struct PluginImportCancellationError: Error, LocalizedError {
    public init() {}
    public var errorDescription: String? { "Import cancelled" }
}

public protocol PluginImportSource: AnyObject, Sendable {
    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error>
    func fileURL() -> URL
    func fileSizeBytes() -> Int64
}

public protocol PluginImportDataSink: AnyObject, Sendable {
    var databaseTypeId: String { get }
    func execute(statement: String) async throws
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    func disableForeignKeyChecks() async throws
    func enableForeignKeyChecks() async throws
}

public extension PluginImportDataSink {
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}

public final class PluginImportProgress: @unchecked Sendable {
    private let progress: Progress
    private let updateInterval: Int = 500
    private var internalCount: Int = 0
    private let lock = NSLock()

    public init(progress: Progress) {
        self.progress = progress
    }

    public func setEstimatedTotal(_ count: Int) {
        progress.totalUnitCount = Int64(count)
    }

    public func incrementStatement() {
        lock.lock()
        internalCount += 1
        let count = internalCount
        let shouldNotify = count % updateInterval == 0
        lock.unlock()
        if shouldNotify {
            progress.completedUnitCount = Int64(count)
        }
    }

    public func setStatus(_ message: String) {
        progress.localizedAdditionalDescription = message
    }

    public func checkCancellation() throws {
        if progress.isCancelled || Task.isCancelled {
            throw PluginImportCancellationError()
        }
    }

    public func cancel() {
        progress.cancel()
    }

    public var isCancelled: Bool {
        progress.isCancelled || Task.isCancelled
    }

    public var processedStatements: Int {
        lock.lock()
        defer { lock.unlock() }
        return internalCount
    }

    public var estimatedTotalStatements: Int {
        Int(progress.totalUnitCount)
    }

    public func finalize() {
        lock.lock()
        let count = internalCount
        lock.unlock()
        progress.completedUnitCount = Int64(count)
    }
}

public protocol ImportFormatPlugin: TableProPlugin {
    static var formatId: String { get }
    static var formatDisplayName: String { get }
    static var acceptedFileExtensions: [String] { get }
    static var iconName: String { get }
    static var supportedDatabaseTypeIds: [String] { get }
    static var excludedDatabaseTypeIds: [String] { get }

    func performImport(
        source: any PluginImportSource,
        sink: any PluginImportDataSink,
        progress: PluginImportProgress
    ) async throws -> PluginImportResult
}

public extension ImportFormatPlugin {
    static var capabilities: [PluginCapability] { [.importFormat] }
    static var supportedDatabaseTypeIds: [String] { [] }
    static var excludedDatabaseTypeIds: [String] { [] }
}
