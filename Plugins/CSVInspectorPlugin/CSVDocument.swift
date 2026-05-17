import AppKit
import TableProPluginKit
import os

public final class CSVDocument: NSDocument, InspectorDocument {
    static let logger = Logger(subsystem: "com.TablePro", category: "CSVInspector")

    private static let typeInferenceSampleSize = 200

    private(set) var store = CSVRowStore(data: Data(), dialect: .csv)
    private(set) var dialect: CSVDialect = .csv
    private(set) var inferredTypes: [InspectorColumnType] = []
    var typeOverrides: [Int: InspectorColumnType] = [:]

    public var onChange: (() -> Void)?

    private var lastInternalWriteTime: Date?
    private var lastReadModificationDate: Date?
    private var isPromptingExternalChange = false

    override public class var autosavesInPlace: Bool { false }

    override public class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { true }

    override public class var readableTypes: [String] {
        ["public.comma-separated-values-text", "public.tab-separated-values-text"]
    }

    override public class var writableTypes: [String] {
        ["public.comma-separated-values-text", "public.tab-separated-values-text"]
    }

    override public func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        Self.writableTypes
    }

    override public func fileNameExtension(
        forType typeName: String,
        saveOperation: NSDocument.SaveOperationType
    ) -> String? {
        typeName == "public.tab-separated-values-text" ? "tsv" : "csv"
    }

    override public func makeWindowControllers() {
        guard let factory = InspectorWindowFactory.make else {
            Self.logger.error("CSVDocument.makeWindowControllers - InspectorWindowFactory.make is nil")
            return
        }
        guard let windowController = factory(self) else {
            Self.logger.error("CSVDocument.makeWindowControllers - factory returned nil")
            return
        }
        addWindowController(windowController)
    }

    override public func read(from url: URL, ofType typeName: String) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var detected = CSVDialect.detect(from: data)
        if typeName == "public.tab-separated-values-text" {
            detected.delimiter = 0x09
        }
        dialect = detected
        store = CSVRowStore(data: data, dialect: detected)
        let sample = store.pageRows(offset: 0, limit: Self.typeInferenceSampleSize)
        inferredTypes = CSVTypeInferrer.inferColumns(rows: sample, columnCount: store.columnCount)
        typeOverrides = [:]
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        lastReadModificationDate = attrs?[.modificationDate] as? Date
    }

    override public func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        NotificationCenter.default.post(name: .inspectorDocumentDidRevert, object: self)
    }

    override public func write(to url: URL, ofType typeName: String) throws {
        try CSVWriter(dialect: dialect).write(store, to: url)
        lastInternalWriteTime = Date()
    }

    override public func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = self.fileURL else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let currentMtime = attrs?[.modificationDate] as? Date
            if let current = currentMtime, let last = self.lastReadModificationDate, current == last {
                Self.logger.debug("presentedItemDidChange: mtime unchanged, skip")
                return
            }
            if let last = self.lastInternalWriteTime, Date().timeIntervalSince(last) < 2.0 {
                return
            }
            if self.isPromptingExternalChange {
                return
            }
            if self.isDocumentEdited {
                self.promptExternalChangeReload(url: url)
            } else {
                self.tryRevert(from: url)
            }
        }
    }

    @MainActor
    private func tryRevert(from url: URL) {
        do {
            try revert(toContentsOf: url, ofType: fileType ?? "public.comma-separated-values-text")
        } catch {
            Self.logger.error("Auto-revert failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
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
                self.tryRevert(from: url)
            }
        }
    }

    override public func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        let edited = isDocumentEdited
        for controller in windowControllers {
            controller.window?.isDocumentEdited = edited
            controller.synchronizeWindowTitleWithDocumentName()
        }
    }

    // MARK: - InspectorDocument

    public var rowCount: Int { store.rowCount }
    public var columnNames: [String] { store.columnNames }

    public func value(row: Int, column: Int) -> String {
        store.value(row: row, column: column)
    }

    public func pageRows(offset: Int, limit: Int) -> [[String]] {
        store.pageRows(offset: offset, limit: limit)
    }

    public func snapshot() -> any InspectorDataSnapshot {
        store.snapshot()
    }

    public func displayedType(forColumn index: Int) -> InspectorColumnType {
        if let override = typeOverrides[index] { return override }
        guard index >= 0, index < inferredTypes.count else { return .text }
        return inferredTypes[index]
    }

    public func setTypeOverride(_ type: InspectorColumnType?, forColumn index: Int) {
        let previous = typeOverrides[index]
        if let type {
            typeOverrides[index] = type
        } else {
            typeOverrides.removeValue(forKey: index)
        }
        guard previous != type else { return }
        registerUndo { document in
            document.setTypeOverride(previous, forColumn: index)
        }
        onChange?()
    }

    public func setCell(row: Int, column: Int, to newValue: String) {
        let previous = store.value(row: row, column: column)
        guard previous != newValue else { return }
        store.setValue(newValue, row: row, column: column)
        registerUndo { document in
            document.setCell(row: row, column: column, to: previous)
        }
        onChange?()
    }

    public func appendRow() {
        let index = store.appendRow(values: [])
        registerUndo { document in
            document.removeRow(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func insertRow(at index: Int) {
        store.insertRow([], at: index)
        registerUndo { document in
            document.removeRow(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func removeRow(at index: Int) {
        removeRow(at: index, suppressUndo: false)
    }

    private func removeRow(at index: Int, suppressUndo: Bool) {
        guard let removed = store.removeRow(at: index) else { return }
        if !suppressUndo {
            registerUndo { document in
                document.reinsertRow(removed, at: index)
            }
        }
        onChange?()
    }

    private func reinsertRow(_ values: [String], at index: Int) {
        store.insertRow(values, at: index)
        registerUndo { document in
            document.removeRow(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func removeRows(at indices: IndexSet) {
        let removed = store.removeRows(at: indices)
        guard !removed.isEmpty else { return }
        registerUndo { document in
            document.reinsertRows(removed)
        }
        onChange?()
    }

    private func reinsertRows(_ rows: [(index: Int, cells: [String])]) {
        for entry in rows.sorted(by: { $0.index < $1.index }) {
            store.insertRow(entry.cells, at: entry.index)
        }
        let originalIndices = IndexSet(rows.map(\.index))
        registerUndo { document in
            document.removeRows(at: originalIndices)
        }
        onChange?()
    }

    public func appendColumn(name: String) {
        let index = store.columnCount
        store.appendColumn(name: name)
        inferredTypes.append(.text)
        registerUndo { document in
            document.removeColumn(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func insertColumn(at index: Int, name: String) {
        store.insertColumn(at: index, name: name, values: [])
        inferredTypes.insert(.text, at: min(max(index, 0), inferredTypes.count))
        shiftTypeOverrides(insertingAt: index)
        registerUndo { document in
            document.removeColumn(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func removeColumn(at index: Int) {
        removeColumn(at: index, suppressUndo: false)
    }

    private func removeColumn(at index: Int, suppressUndo: Bool) {
        guard let removed = store.removeColumn(at: index) else { return }
        let removedType = (index < inferredTypes.count) ? inferredTypes.remove(at: index) : .text
        let removedOverride = typeOverrides[index]
        shiftTypeOverrides(removingAt: index)
        if !suppressUndo {
            registerUndo { document in
                document.reinsertColumn(
                    name: removed.name,
                    values: removed.values,
                    inferredType: removedType,
                    override: removedOverride,
                    at: index
                )
            }
        }
        onChange?()
    }

    private func reinsertColumn(
        name: String,
        values: [String],
        inferredType: InspectorColumnType,
        override: InspectorColumnType?,
        at index: Int
    ) {
        store.insertColumn(at: index, name: name, values: values)
        inferredTypes.insert(inferredType, at: min(max(index, 0), inferredTypes.count))
        shiftTypeOverrides(insertingAt: index)
        if let override {
            typeOverrides[index] = override
        }
        registerUndo { document in
            document.removeColumn(at: index, suppressUndo: false)
        }
        onChange?()
    }

    public func renameColumn(at index: Int, to name: String) {
        guard let previous = store.renameColumn(at: index, to: name), previous != name else { return }
        registerUndo { document in
            document.renameColumn(at: index, to: previous)
        }
        onChange?()
    }

    private func registerUndo(_ action: @escaping (CSVDocument) -> Void) {
        undoManager?.registerUndo(withTarget: self, handler: action)
    }

    private func shiftTypeOverrides(insertingAt index: Int) {
        typeOverrides = typeOverrides.reduce(into: [Int: InspectorColumnType]()) { result, entry in
            result[entry.key >= index ? entry.key + 1 : entry.key] = entry.value
        }
    }

    private func shiftTypeOverrides(removingAt index: Int) {
        var shifted: [Int: InspectorColumnType] = [:]
        for (key, value) in typeOverrides where key != index {
            shifted[key > index ? key - 1 : key] = value
        }
        typeOverrides = shifted
    }
}
