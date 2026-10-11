//
//  DataSourceExportRequest.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal struct DataSourceExportScope: Identifiable {
    internal let id: String
    internal let title: String
    internal let rowCount: Int?
    internal let makeDataSource: @MainActor () -> any PluginExportDataSource

    internal init(
        id: String,
        title: String,
        rowCount: Int?,
        makeDataSource: @escaping @MainActor () -> any PluginExportDataSource
    ) {
        self.id = id
        self.title = title
        self.rowCount = rowCount
        self.makeDataSource = makeDataSource
    }
}

internal struct DataSourceExportRequest {
    internal static let dataFileTypeId = "DataFile"

    internal let title: String
    internal let suggestedFileName: String
    internal let databaseTypeId: String
    internal let scopes: [DataSourceExportScope]
    internal let initialScopeId: String?

    internal init(
        title: String,
        suggestedFileName: String,
        databaseTypeId: String = DataSourceExportRequest.dataFileTypeId,
        scopes: [DataSourceExportScope],
        initialScopeId: String? = nil
    ) {
        self.title = title
        self.suggestedFileName = suggestedFileName
        self.databaseTypeId = databaseTypeId
        self.scopes = scopes
        self.initialScopeId = initialScopeId
    }

    internal var initialScope: DataSourceExportScope? {
        scope(withId: initialScopeId) ?? scopes.first
    }

    internal func scope(withId id: String?) -> DataSourceExportScope? {
        guard let id else { return nil }
        return scopes.first { $0.id == id }
    }
}
