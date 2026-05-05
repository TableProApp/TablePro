//
//  LinkedFavoriteTransfer.swift
//  TablePro
//

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

internal struct LinkedFavoriteTransfer: Transferable {
    let fileURL: URL

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .utf8PlainText) { item in
            let loaded = FileTextLoader.load(item.fileURL)
            return Data((loaded?.content ?? "").utf8)
        }
    }
}
