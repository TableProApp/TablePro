//
//  ConnectionExportDocument.swift
//  TablePro
//

import SwiftUI
import TableProImport
import UniformTypeIdentifiers

struct ConnectionExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.tableproConnectionShare]
    static let writableContentTypes: [UTType] = [.tableproConnectionShare]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
