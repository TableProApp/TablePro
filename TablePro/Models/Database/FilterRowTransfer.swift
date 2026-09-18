//
//  FilterRowTransfer.swift
//  TablePro
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

internal extension UTType {
    static let tableProFilterRow = UTType(exportedAs: "com.tablepro.filter-row")
}

internal struct FilterRowTransfer: Codable, Transferable {
    let filterID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tableProFilterRow)
    }
}
