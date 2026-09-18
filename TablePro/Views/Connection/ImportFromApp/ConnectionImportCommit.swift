import Foundation
import TableProImport

@MainActor
enum ConnectionImportCommit {
    static func perform(
        preview: ConnectionImportPreview,
        selectedIds: Set<UUID>,
        duplicateResolutions: [UUID: ImportResolution]
    ) -> Int {
        var resolutions: [UUID: ImportResolution] = [:]
        for item in preview.items {
            guard selectedIds.contains(item.id) else {
                resolutions[item.id] = .skip
                continue
            }
            switch item.status {
            case .ready, .warnings, .unsupportedType:
                resolutions[item.id] = .importNew
            case .duplicate:
                resolutions[item.id] = duplicateResolutions[item.id] ?? .importAsCopy
            }
        }

        let result = ConnectionExportService.performImport(preview, resolutions: resolutions)
        if preview.envelope.credentials != nil {
            ConnectionExportService.restoreCredentials(
                from: preview.envelope,
                connectionIdMap: result.newConnectionIdMap
            )
        }
        return result.importedCount
    }
}
