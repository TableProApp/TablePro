//
//  DataFileController.swift
//  TablePro
//

import AppKit
import Combine
import os
import TableProPluginKit
import TableProTabular
import TableProTabularIO

enum DataFileLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

struct DataFileActivity: Equatable {
    let id: UUID
    let title: String
    var fraction: Double
    let isMutation: Bool
    var isVisible: Bool
}

@MainActor
final class DataFileController: ObservableObject {
    static let logger = Logger(subsystem: "com.TablePro", category: "DataFiles")
    static let activityRevealDelay: Duration = .milliseconds(300)

    @Published private(set) var loadState: DataFileLoadState = .idle
    @Published private(set) var loadProgress: Double = 0
    @Published private(set) var table: TabularTable?
    @Published private(set) var columnNames = DataFileColumnNames(columns: [])
    @Published private(set) var inferredKinds: [TabularColumnID: TabularInferredKind] = [:]
    @Published var kindOverrides: [TabularColumnID: TabularInferredKind] = [:]
    @Published private(set) var sheets: [DataFileSheet] = []
    @Published private(set) var selectedSheetIndex = 0
    @Published private(set) var dialect: DelimitedDialect?
    @Published private(set) var raggedRowCount = 0

    @Published var filterState = TabFilterState()
    @Published var searchText = ""
    @Published var sortState = SortState()
    @Published private(set) var displayKeys: [Int]?
    @Published private(set) var isQueryRunning = false

    @Published var pageOffset = 0
    @Published var pageSize: Int
    @Published private(set) var tableRows = TableRows()
    @Published private(set) var pageRevision = 0
    @Published var selectedRowIndices: Set<Int> = []
    @Published var columnLayout = ColumnLayoutState()
    @Published var isInspectorVisible = false

    @Published var find = DataFileFindState()
    @Published private(set) var activity: DataFileActivity?
    @Published var statusMessage: String?

    let changeManager: DataFileChangeManager
    let anyChangeManager: AnyChangeManager
    weak var undoManager: UndoManager?
    weak var gridCoordinator: TableViewCoordinator?
    var onEdited: (() -> Void)?

    private(set) var kind: DataFileKind?
    private(set) var content: DataFileContent?
    private(set) var pageKeys: [Int] = []
    private var workingCopy: DataFileWorkingCopy?
    private var loadTask: Task<Void, Never>?
    private var queryTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?
    private var queryDebounceTask: Task<Void, Never>?
    var findTask: Task<Void, Never>?
    var findDebounceTask: Task<Void, Never>?
    var transferTask: Task<Void, Never>?
    private var activityRevealTask: Task<Void, Never>?
    private var messageTask: Task<Void, Never>?
    private var queryRevision = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        pageSize = max(1, AppSettingsManager.shared.dataGrid.defaultPageSize)
        changeManager = DataFileChangeManager()
        anyChangeManager = AnyChangeManager(changeManager)
    }

    var isEditable: Bool {
        (kind?.isEditable ?? false) && loadState == .loaded
    }

    var visibleRowCount: Int {
        displayKeys?.count ?? table?.rowCount ?? 0
    }

    var totalRowCount: Int {
        table?.rowCount ?? 0
    }

    var pageCount: Int {
        let visible = visibleRowCount
        return visible == 0 ? 1 : (visible + pageSize - 1) / pageSize
    }

    var isBusy: Bool {
        activity?.isMutation ?? false
    }

    func kind(of id: TabularColumnID) -> TabularInferredKind {
        kindOverrides[id] ?? inferredKinds[id] ?? .text
    }

    func load(url: URL, kind: DataFileKind, dialectOverride: DelimitedDialect? = nil) {
        loadTask?.cancel()
        queryTask?.cancel()
        mutationTask?.cancel()
        self.kind = kind
        loadState = .loading
        loadProgress = 0
        let request = DataFileLoadRequest(url: url, kind: kind, dialectOverride: dialectOverride)
        loadTask = Task { [weak self] in
            await self?.performLoad(request)
        }
    }

    func waitForPendingWork() async {
        await loadTask?.value
        await queryDebounceTask?.value
        await queryTask?.value
        await mutationTask?.value
        await findDebounceTask?.value
        await findTask?.value
        await transferTask?.value
    }

    private func performLoad(_ request: DataFileLoadRequest) async {
        do {
            let workingCopy = try DataFileWorkingCopy()
            let content = try await DataFileLoader.load(request, workingCopy: workingCopy) { fraction in
                Task { @MainActor [weak self] in
                    self?.loadProgress = fraction
                }
            }
            try Task.checkCancellation()
            self.workingCopy = workingCopy
            install(content)
        } catch {
            guard !error.isDataFileCancellation, !Task.isCancelled else {
                Self.logger.debug("Data file load cancelled")
                return
            }
            Self.logger.error("Data file load failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
            loadState = .failed(error.localizedDescription)
        }
    }

    private func install(_ content: DataFileContent) {
        self.content = content
        sheets = content.sheets
        dialect = content.dialect
        raggedRowCount = content.raggedRowCount
        selectedSheetIndex = content.initialSheetIndex
        undoManager?.removeAllActions()
        installSheet(at: content.initialSheetIndex)
    }

    func selectSheet(_ index: Int) {
        guard sheets.indices.contains(index), index != selectedSheetIndex, !isBusy else { return }
        storeCurrentSheet()
        selectedSheetIndex = index
        guard sheets[index].table == nil else {
            installSheet(at: index)
            return
        }
        loadSheet(at: index)
    }

    private func storeCurrentSheet() {
        guard let table, sheets.indices.contains(selectedSheetIndex) else { return }
        sheets[selectedSheetIndex].table = table
        sheets[selectedSheetIndex].kinds = inferredKinds
    }

    private func loadSheet(at index: Int) {
        guard let workbook = content?.workbook, let workbookSheet = sheets[index].workbookSheet else { return }
        queryTask?.cancel()
        findTask?.cancel()
        loadTask?.cancel()
        table = nil
        loadState = .loading
        loadProgress = 0
        let reportProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.loadProgress = fraction
            }
        }
        loadTask = Task { [weak self] in
            do {
                let loaded = try await DataFileLoader.loadSheet(workbookSheet, of: workbook, progress: reportProgress)
                guard let self, self.selectedSheetIndex == index else { return }
                self.sheets[index].table = loaded.table
                self.sheets[index].kinds = loaded.kinds
                self.installSheet(at: index)
            } catch {
                guard let self, !error.isDataFileCancellation, self.selectedSheetIndex == index else { return }
                Self.logger.error("Sheet load failed: \(error.publicLogShape, privacy: .public) \(error.localizedDescription, privacy: .private)")
                self.loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func installSheet(at index: Int) {
        let sheet = sheets[index]
        guard let sheetTable = sheet.table else { return }
        table = sheetTable
        inferredKinds = sheet.kinds
        kindOverrides = [:]
        filterState = TabFilterState()
        searchText = ""
        sortState = SortState()
        displayKeys = nil
        pageOffset = 0
        selectedRowIndices = []
        refreshColumnNames()
        refreshPage()
        loadState = .loaded
    }

    func refreshColumnNames() {
        guard let table else {
            columnNames = DataFileColumnNames(columns: [])
            return
        }
        let updated = DataFileColumnNames(columns: table.columns)
        if updated != columnNames {
            columnNames = updated
        }
    }

    func key(forPageRow pageRow: Int) -> Int? {
        pageKeys.indices.contains(pageRow) ? pageKeys[pageRow] : nil
    }

    func logicalRow(forKey key: Int) -> Int? {
        table?.rowOrder.logicalRow(ofKey: key)
    }

    func displayPosition(ofKey key: Int) -> Int? {
        if let displayKeys {
            return displayKeys.firstIndex(of: key)
        }
        return logicalRow(forKey: key)
    }

    func key(atDisplayPosition position: Int) -> Int? {
        guard let table, position >= 0 else { return nil }
        if let displayKeys {
            return position < displayKeys.count ? displayKeys[position] : nil
        }
        return position < table.rowCount ? table.key(atRow: position) : nil
    }

    func visibleKeys() -> [Int] {
        guard let table else { return [] }
        return displayKeys ?? table.rowOrder.keys
    }

    func refreshPage() {
        guard let table else {
            tableRows = TableRows()
            pageKeys = []
            changeManager.bumpReload()
            return
        }
        let visible = visibleRowCount
        let size = max(pageSize, 1)
        let maxOffset = visible == 0 ? 0 : ((visible - 1) / size) * size
        pageOffset = min(max(pageOffset, 0), maxOffset)
        let end = min(pageOffset + size, visible)
        var keys: [Int] = []
        keys.reserveCapacity(max(0, end - pageOffset))
        for position in pageOffset..<max(pageOffset, end) {
            if let key = key(atDisplayPosition: position) {
                keys.append(key)
            }
        }
        let ids = columnNames.ids
        var rowsByKey: [Int: ContiguousArray<PluginCellValue>] = [:]
        rowsByKey.reserveCapacity(keys.count)
        table.scan(columns: ids, keys: keys) { key, cells in
            var values = ContiguousArray<PluginCellValue>()
            values.reserveCapacity(cells.count)
            for index in 0..<cells.count {
                values.append(cells.kinds[index].isNullLike ? .null : .text(cells.string(at: index)))
            }
            rowsByKey[key] = values
            return true
        }
        var rows = ContiguousArray<Row>()
        rows.reserveCapacity(keys.count)
        for key in keys {
            let values = rowsByKey[key] ?? ContiguousArray(repeating: .text(""), count: ids.count)
            rows.append(Row(id: .existing(key), values: values))
        }
        pageKeys = keys
        pageRevision &+= 1
        let names = columnNames.displayNames
        let holdsNull = kind?.holdsNull ?? false
        tableRows = TableRows(
            rows: rows,
            columns: names,
            columnTypes: ids.map { _ in ColumnType.text(rawType: "TEXT") },
            columnNullable: Dictionary(uniqueKeysWithValues: names.map { ($0, holdsNull) })
        )
        changeManager.bumpReload()
        gridCoordinator?.applyDelta(.fullReplace)
    }

    func goToPage(offsetBy delta: Int) {
        let target = pageOffset + delta * pageSize
        guard target >= 0, target < max(visibleRowCount, 1) else { return }
        pageOffset = target
        selectedRowIndices = []
        refreshPage()
    }

    func reveal(key: Int, selecting: Bool = true) {
        guard let position = displayPosition(ofKey: key) else { return }
        let size = max(pageSize, 1)
        let page = (position / size) * size
        if page != pageOffset {
            pageOffset = page
            refreshPage()
        }
        let row = position - pageOffset
        guard selecting, row >= 0, row < pageKeys.count else { return }
        selectedRowIndices = [row]
        DispatchQueue.main.async { [weak self] in
            guard let coordinator = self?.gridCoordinator, let tableView = coordinator.tableView,
                  row < tableView.numberOfRows else { return }
            coordinator.isApplyingProgrammaticRowSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            coordinator.isApplyingProgrammaticRowSelection = false
            tableView.scrollRowToVisible(row)
        }
    }

    func showMessage(_ message: String) {
        statusMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    func beginActivity(title: String, isMutation: Bool) -> UUID {
        let id = UUID()
        activity = DataFileActivity(id: id, title: title, fraction: 0, isMutation: isMutation, isVisible: false)
        activityRevealTask?.cancel()
        activityRevealTask = Task { [weak self] in
            try? await Task.sleep(for: Self.activityRevealDelay)
            guard !Task.isCancelled, let self, self.activity?.id == id else { return }
            self.activity?.isVisible = true
        }
        return id
    }

    func reportProgress(_ fraction: Double, for id: UUID) {
        guard activity?.id == id else { return }
        activity?.fraction = fraction
    }

    func endActivity(_ id: UUID) {
        guard activity?.id == id else { return }
        activity = nil
        activityRevealTask?.cancel()
    }

    func progressReporter(for id: UUID) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in
                self?.reportProgress(fraction, for: id)
            }
        }
    }

    func cancelActivity() {
        queryTask?.cancel()
        mutationTask?.cancel()
        findTask?.cancel()
        transferTask?.cancel()
    }

    func tearDown() {
        loadTask?.cancel()
        queryTask?.cancel()
        mutationTask?.cancel()
        queryDebounceTask?.cancel()
        findTask?.cancel()
        findDebounceTask?.cancel()
        transferTask?.cancel()
        activityRevealTask?.cancel()
        messageTask?.cancel()
        workingCopy = nil
    }

    func setQueryTask(_ task: Task<Void, Never>?) {
        queryTask?.cancel()
        queryTask = task
    }

    func setMutationTask(_ task: Task<Void, Never>?) {
        mutationTask = task
    }

    var hasMutationInFlight: Bool {
        mutationTask != nil && activity?.isMutation == true
    }

    func setDebounceTask(_ task: Task<Void, Never>?) {
        queryDebounceTask?.cancel()
        queryDebounceTask = task
    }

    func nextQueryRevision() -> Int {
        queryRevision += 1
        return queryRevision
    }

    func isCurrentQuery(_ revision: Int) -> Bool {
        revision == queryRevision
    }

    var currentQueryRevision: Int {
        queryRevision
    }

    func setQueryRunning(_ running: Bool) {
        isQueryRunning = running
    }

    func setDisplayKeys(_ keys: [Int]?) {
        displayKeys = keys
    }

    func replaceTable(_ newTable: TabularTable) {
        table = newTable
        if sheets.indices.contains(selectedSheetIndex) {
            sheets[selectedSheetIndex].table = newTable
        }
        refreshColumnNames()
    }

    func setInferredKind(_ kind: TabularInferredKind, for id: TabularColumnID) {
        inferredKinds[id] = kind
    }

    func removeKinds(for ids: Set<TabularColumnID>) {
        for id in ids {
            inferredKinds[id] = nil
            kindOverrides[id] = nil
        }
    }

    func setDialect(_ newDialect: DelimitedDialect) {
        dialect = newDialect
    }
}
