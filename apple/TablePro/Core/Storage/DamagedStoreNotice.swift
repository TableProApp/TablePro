import AppKit

enum DamagedStoreNotice {
    static func queryHistorySetAside(_ setAside: SetAsideDamagedStore) {
        let message = String(
            format: String(
                localized: """
                    TablePro could not read its query history, so it moved the file aside as “%@” and started a new one. \
                    The copy stays until you delete it or clear all of your history.
                    """
            ),
            setAside.setAsideURL.lastPathComponent
        )
        Task { @MainActor in
            present(title: String(localized: "Query History Was Damaged"), message: message, setAside: setAside)
        }
    }

    static func savedQueriesSetAside(_ setAside: SetAsideDamagedStore) {
        let message = String(
            format: String(
                localized: """
                    TablePro could not read its saved queries, so it moved the file aside as “%@” and started an empty one. \
                    Nothing in that file was deleted.
                    """
            ),
            setAside.setAsideURL.lastPathComponent
        )
        Task { @MainActor in
            present(title: String(localized: "Saved Queries Were Damaged"), message: message, setAside: setAside)
        }
    }

    @MainActor
    private static func present(title: String, message: String, setAside: SetAsideDamagedStore) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Show in Finder"))
        AlertHelper.present(alert, in: nil) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.activateFileViewerSelecting([setAside.setAsideURL])
        }
    }
}
