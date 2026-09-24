//
//  DataFileSplitViewController+Transfer.swift
//  TablePro
//

import AppKit

extension DataFileSplitViewController {
    func presentExport() {
        guard let window = view.window,
              let request = controller.exportRequest(title: exportTitle, suggestedFileName: exportFileName) else { return }
        exportPresenter.present(request, on: window)
    }

    func importTargets() -> [ConnectedSessionSummary] {
        ConnectedSessionDirectory.connectedSessions().filter { !$0.isReadOnly }
    }

    func presentImportIntoTable() {
        let targets = importTargets()
        guard !targets.isEmpty, let window = view.window else { return }
        DataFilePrompts.importTarget(from: targets, window: window) { [weak self] target in
            guard let self, let target else { return }
            self.beginImport(into: target)
        }
    }

    private func beginImport(into target: ConnectedSessionSummary) {
        guard let coordinator = ConnectedSessionDirectory.coordinator(for: target.id) else {
            presentImportFailure(String(localized: "That connection is no longer open."))
            return
        }
        if let refusal = coordinator.rowImportRefusal(formatId: DataFileImportFormat.formatId) {
            presentImportFailure(refusal.localizedDescription)
            return
        }
        controller.prepareImportSnapshot { [weak self] snapshot in
            self?.handOff(snapshot, to: target)
        }
    }

    private func handOff(_ snapshot: DataFileImportSnapshot, to target: ConnectedSessionSummary) {
        guard let coordinator = ConnectedSessionDirectory.coordinator(for: target.id) else {
            ImportFileHandoff(url: snapshot.url, ownsFile: true).discard()
            presentImportFailure(String(localized: "That connection is no longer open."))
            return
        }
        guard let refusal = coordinator.presentRowImport(of: snapshot.url, formatId: snapshot.formatId, ownsFile: true) else {
            return
        }
        ImportFileHandoff(url: snapshot.url, ownsFile: true).discard()
        if case .importNotSupported = refusal { return }
        presentImportFailure(refusal.localizedDescription)
    }

    private func presentImportFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Cannot Import")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        AlertHelper.present(alert, in: view.window) { _ in }
    }

    private var exportTitle: String {
        dataFileDocument?.displayName ?? String(localized: "Data File")
    }

    private var exportFileName: String {
        guard let url = dataFileDocument?.fileURL else { return String(localized: "Untitled") }
        return url.deletingPathExtension().lastPathComponent
    }
}
