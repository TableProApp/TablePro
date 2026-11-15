import Foundation
import TableProDatabase
import TableProModels

nonisolated struct MobileTransferContext: Sendable, Equatable {
    let databaseType: DatabaseType
    let database: String?
    let schema: String?
}

// A driver that can take part in an export or an import. Each engine conforms its own driver in its own file;
// a driver that does not conform offers neither.
nonisolated protocol MobileTransferEngine: DatabaseDriver {
    func makeExportCatalog(context: MobileTransferContext) async throws -> any MobileExportCatalog
    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect
    // Whether each table `fetchTables` lists is an object of the export catalog, so it can be exported on its own.
    var exportsListedTables: Bool { get }
}

nonisolated extension MobileTransferEngine {
    var exportsListedTables: Bool { true }

    func makeWriteDialect(context: MobileTransferContext) async throws -> any MobileWriteDialect {
        throw MobileTransferRefusal(reason: String(
            format: String(localized: "%@ cannot take rows from a file."), context.databaseType.mobileDisplayName
        ))
    }
}
