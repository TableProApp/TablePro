//
//  DataFileDocumentController.swift
//  TablePro
//

import AppKit

final class DataFileDocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? {
        guard DataFileKind.readableTypes.contains(typeName) else {
            return super.documentClass(forType: typeName)
        }
        return DataFileDocument.self
    }

    override func typeForContents(of url: URL) throws -> String {
        guard let kind = DataFileKind.classify(url) else {
            return try super.typeForContents(of: url)
        }
        return kind.typeIdentifier
    }
}
