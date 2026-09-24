//
//  DataFileDocument.swift
//  TablePro
//

import AppKit
import os
import TableProTabularIO

final class DataFileDocument: NSDocument {
    private static let logger = Logger(subsystem: "com.TablePro", category: "DataFiles")
    private static let ownWriteGrace: TimeInterval = 2

    let controller: DataFileController
    private var lastOwnWrite: Date?
    private var lastReadModificationDate: Date?
    private var isPromptingExternalChange = false

    override init() {
        controller = MainActor.assumeIsolated { DataFileController() }
        super.init()
        hasUndoManager = true
        MainActor.assumeIsolated {
            controller.undoManager = undoManager
        }
    }

    override class var autosavesInPlace: Bool { false }

    override class var readableTypes: [String] { DataFileKind.readableTypes }

    override class var writableTypes: [String] { DataFileKind.editableTypes }

    override class func isNativeType(_ type: String) -> Bool {
        DataFileKind.editableTypes.contains(type)
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        let kind = MainActor.assumeIsolated { controller.kind }
        switch saveOperation {
        case .saveOperation:
            return (kind?.isEditable ?? false) ? [kind?.typeIdentifier ?? DataFileKind.commaSeparatedType] : []
        case .saveAsOperation, .saveToOperation, .autosaveElsewhereOperation, .autosaveInPlaceOperation,
             .autosaveAsOperation:
            return Self.saveAsTypes(for: kind)
        @unknown default:
            return Self.saveAsTypes(for: kind)
        }
    }

    private static func saveAsTypes(for kind: DataFileKind?) -> [String] {
        switch kind?.format {
        case .json?, .jsonLines?:
            return [DataFileKind.jsonType, DataFileKind.jsonLinesType, DataFileKind.commaSeparatedType,
                    DataFileKind.tabSeparatedType]
        case .delimited?, .workbook?, nil:
            return [DataFileKind.commaSeparatedType, DataFileKind.tabSeparatedType, DataFileKind.pipeSeparatedType]
        }
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        DataFileKind.fileExtension(forType: typeName) ?? super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func makeWindowControllers() {
        MainActor.assumeIsolated {
            addWindowController(DataFileWindowController(document: self))
        }
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        guard let kind = DataFileKind.kind(forTypeIdentifier: typeName, url: url) else {
            throw DataFileLoadError.unsupported(String(localized: "This kind of file cannot be opened as a table."))
        }
        let modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        MainActor.assumeIsolated {
            lastReadModificationDate = modificationDate
            controller.load(url: url, kind: kind)
        }
    }

    override nonisolated func write(to url: URL, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            try controller.write(to: url, typeName: typeName)
            lastOwnWrite = Date()
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)):
            return controller.isEditable && !controller.hasMutationInFlight && super.validateUserInterfaceItem(item)
        case #selector(saveAs(_:)), #selector(saveTo(_:)), #selector(revertToSaved(_:)):
            return controller.loadState == .loaded && !controller.hasMutationInFlight
                && super.validateUserInterfaceItem(item)
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func close() {
        controller.tearDown()
        super.close()
    }

    func reload(with dialect: DelimitedDialect?) {
        guard let url = fileURL, let kind = controller.kind else { return }
        controller.load(url: url, kind: kind, dialectOverride: dialect)
        updateChangeCount(.changeCleared)
    }

    override nonisolated func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            self?.handleExternalChange()
        }
    }

    private func handleExternalChange() {
        guard let url = fileURL else { return }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let modified, let last = lastReadModificationDate, modified == last { return }
        if let lastOwnWrite, Date().timeIntervalSince(lastOwnWrite) < Self.ownWriteGrace { return }
        guard !isPromptingExternalChange else { return }
        guard isDocumentEdited else {
            revertQuietly(to: url)
            return
        }
        promptExternalChangeReload(url: url)
    }

    private func revertQuietly(to url: URL) {
        do {
            try revert(toContentsOf: url, ofType: fileType ?? controller.kind?.typeIdentifier ?? DataFileKind.commaSeparatedType)
        } catch {
            Self.logger.error("Reload after an outside change failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    private func promptExternalChangeReload(url: URL) {
        guard let window = windowControllers.first?.window else { return }
        isPromptingExternalChange = true
        let alert = NSAlert()
        alert.messageText = String(localized: "File modified externally")
        alert.informativeText = String(localized: "Another app changed this file. Discard your unsaved changes and reload?")
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.addButton(withTitle: String(localized: "Keep Changes"))
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isPromptingExternalChange = false
            if response == .alertFirstButtonReturn {
                self.revertQuietly(to: url)
            }
        }
    }
}
