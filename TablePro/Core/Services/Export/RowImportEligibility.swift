//
//  RowImportEligibility.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal enum RowImportRefusal: LocalizedError, Equatable {
    case readOnly(connectionName: String)
    case importNotSupported(DatabaseType)
    case formatNotOffered(formatId: String)
    case sheetAlreadyPresented(connectionName: String)

    internal var errorDescription: String? {
        switch self {
        case .readOnly(let connectionName):
            return String(format: String(localized: "%@ is read-only, so nothing can be written to it."), connectionName)
        case .importNotSupported(let databaseType):
            return String(format: String(localized: "Import is not supported for %@ connections."), databaseType.rawValue)
        case .formatNotOffered(let formatId):
            return String(
                format: String(localized: "%@ files cannot be imported into this connection."),
                formatId.uppercased()
            )
        case .sheetAlreadyPresented(let connectionName):
            return String(
                format: String(localized: "%@ is showing another sheet. Close it, then try again."),
                connectionName
            )
        }
    }
}

@MainActor
internal struct ImportFormatLookup {
    internal var supportsImport: (DatabaseType) -> Bool
    internal var offeredFormats: (DatabaseType) -> [ImportFormatOption]
    internal var requiresTargetTable: (String) -> Bool?

    internal static let live = ImportFormatLookup(
        supportsImport: { PluginManager.shared.supportsImport(for: $0) },
        offeredFormats: { PluginManager.shared.importFormatOptions(for: $0) },
        requiresTargetTable: { formatId in
            PluginManager.shared.importPlugin(forFormat: formatId).map { type(of: $0).requiresTargetTable }
        }
    )
}

@MainActor
internal enum RowImportEligibility {
    internal static func refusal(
        formatId: String,
        databaseType: DatabaseType,
        connectionName: String,
        safeModeLevel: SafeModeLevel,
        isPresentingSheet: Bool,
        lookup: ImportFormatLookup
    ) -> RowImportRefusal? {
        guard !safeModeLevel.blocksAllWrites else {
            return .readOnly(connectionName: connectionName)
        }
        guard lookup.supportsImport(databaseType) else {
            return .importNotSupported(databaseType)
        }
        guard lookup.offeredFormats(databaseType).contains(where: { $0.id == formatId }),
              lookup.requiresTargetTable(formatId) == true else {
            return .formatNotOffered(formatId: formatId)
        }
        guard !isPresentingSheet else {
            return .sheetAlreadyPresented(connectionName: connectionName)
        }
        return nil
    }
}
