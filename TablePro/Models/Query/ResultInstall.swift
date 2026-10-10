//
//  ResultInstall.swift
//  TablePro
//

import Foundation

/// The value filter, sort and selection belong to what the rows were read from, not to one batch
/// of them, so they outlive a re-read of the same source and go with a new one.
internal enum ResultSourceChange: Equatable {
    case newSource
    case sameSource
    /// One result of a query tab read again. It lands only in that result, while it is still on screen.
    case reread(RereadTarget)

    var keepsViewState: Bool { self != .newSource }
}

internal struct RereadTarget: Equatable {
    let tabId: UUID
    let resultId: UUID?
    let databaseName: String
    let schemaName: String?
}

/// How a result that lands treats the grid it replaces.
internal struct ResultInstall: Equatable {
    var viewport: GridReloadIntent
    var source: ResultSourceChange
    /// A re-read keeps the statement its result already points back at.
    var anchor: StatementAnchor?

    init(viewport: GridReloadIntent = .firstRow, source: ResultSourceChange = .newSource, anchor: StatementAnchor? = nil) {
        self.viewport = viewport
        self.source = source
        self.anchor = anchor
    }

    static let newResult = ResultInstall()
}
