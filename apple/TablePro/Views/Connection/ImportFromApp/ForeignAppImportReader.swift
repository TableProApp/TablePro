//
//  ForeignAppImportReader.swift
//  TablePro
//

import Foundation
import TableProImport

struct ForeignAppRead {
    let preview: ImportPreview
    let title: String
    let banner: ImportReviewBanner?
}

// One read per app, checked against the library the previous apply left, so a second app's rows see the first's.
enum ForeignAppImportReader {
    @MainActor
    static func read(_ importer: any ForeignAppImporter, request: ForeignImportRequest) async throws -> ForeignAppRead {
        let collected = try await collect(from: importer, request: request)
        try Task.checkCancellation()
        let preview = try await ImportReviewLoader.preview(of: collected)
        try Task.checkCancellation()
        return ForeignAppRead(
            preview: preview,
            title: String(format: String(localized: "Import from %@"), importer.displayName),
            banner: collected.credentialsAborted ? .credentialsNotRead : nil
        )
    }

    @concurrent
    nonisolated private static func collect(
        from importer: any ForeignAppImporter,
        request: ForeignImportRequest
    ) async throws -> CollectedImport {
        try importer.collect(request)
    }
}
