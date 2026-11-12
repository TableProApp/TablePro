import Combine
import Foundation

@MainActor
final class GridFindState: ObservableObject {
    struct Options: Equatable, Sendable {
        var matchesCase = false
        var matchesWholeWord = false
        var usesRegularExpression = false
        var columnScope: DataGridColumnID?
    }

    struct Match: Hashable, Sendable {
        let rowID: RowID
        let columnID: DataGridColumnID
    }

    // What a search of the loaded rows does once its matches land.
    struct Landing: Equatable {
        // A typed term selects the first match from the cursor; a refresh keeps the current match.
        var revealsFirstMatch = false
        // The active cell when the typed term's search began. A user who moved it since keeps their place.
        var cursorAtStart: Match?
        // Find Next presses minus Find Previous presses while the search ran.
        var steps = 0
    }

    @Published var isVisible = false
    @Published var showsReplace = false
    @Published var term = ""
    @Published var replacement = ""
    @Published var options = Options()
    @Published private(set) var matches: [Match] = []
    @Published private(set) var currentIndex: Int?
    @Published private(set) var problem: String?
    @Published private(set) var isSearching = false
    // The user stopped a whole-dataset search before it finished.
    @Published private(set) var searchStopped = false
    // An empty match list means nothing yet; unlike isSearching it shows no progress.
    @Published private(set) var isAwaitingLoadedRows = false

    weak var datasetFinder: (any DataGridDatasetFinding)?
    private(set) var datasetQuery: GridDatasetFindQuery?
    private(set) var datasetSearch: Task<Void, Never>?
    private var datasetGeneration = 0
    // What the matches were searched on, while they came from the loaded rows; nil once anything else set them.
    private(set) var loadedRowsBasis: GridFindEngine.Basis?
    // Runs off the main actor and sets no isSearching: a refresh keeps the matches shown until the new ones land.
    private(set) var loadedRowsSearch: Task<Void, Never>?
    private var loadedRowsGeneration = 0
    private var loadedRowsLanding = Landing()

    // A closed grid's scan would otherwise run to the end and hold its rows until then.
    deinit {
        loadedRowsSearch?.cancel()
        datasetSearch?.cancel()
    }

    var currentMatch: Match? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    func setResults(_ matches: [Match], current: Int?, problem: String?, basis: GridFindEngine.Basis? = nil) {
        self.matches = matches
        self.currentIndex = current.flatMap { matches.indices.contains($0) ? $0 : nil }
        self.problem = problem
        loadedRowsBasis = basis
    }

    func setCurrentIndex(_ index: Int?) {
        currentIndex = index.flatMap { matches.indices.contains($0) ? $0 : nil }
    }

    // The next match takes the removed one's place, wrapping to the first.
    func removeMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        matches.remove(at: index)
        loadedRowsBasis = nil
        currentIndex = matches.isEmpty ? nil : (index < matches.count ? index : 0)
    }

    func reset() {
        cancelDatasetSearch()
        cancelLoadedRowsSearch()
        datasetQuery = nil
        searchStopped = false
        term = ""
        replacement = ""
        matches = []
        loadedRowsBasis = nil
        currentIndex = nil
        problem = nil
    }

    // MARK: - Loaded-rows search

    // The search hands this generation back when it lands. Any other search stops, and a running one this
    // replaces hands on what it was to do on landing.
    func beginLoadedRowsSearch(_ landing: Landing) -> Int {
        var merged = landing
        if loadedRowsSearch != nil {
            if !landing.revealsFirstMatch, loadedRowsLanding.revealsFirstMatch {
                merged.revealsFirstMatch = true
                merged.cursorAtStart = loadedRowsLanding.cursorAtStart
            }
            merged.steps += loadedRowsLanding.steps
        }
        cancelLoadedRowsSearch()
        if datasetSearch != nil {
            cancelDatasetSearch()
        }
        loadedRowsLanding = merged
        loadedRowsBasis = nil
        // The old term's count and current match would read as the new term's until the scan lands.
        if merged.revealsFirstMatch {
            matches = []
            currentIndex = nil
            problem = nil
        }
        return loadedRowsGeneration
    }

    func attachLoadedRowsSearch(_ task: Task<Void, Never>, generation: Int) {
        guard generation == loadedRowsGeneration else {
            task.cancel()
            return
        }
        loadedRowsSearch = task
        // Set here, not in begin, so a term answered without scanning never publishes it.
        isAwaitingLoadedRows = true
    }

    // Nil when a later search, a reset or a dataset search took this one's place.
    func endLoadedRowsSearch(generation: Int) -> Landing? {
        guard generation == loadedRowsGeneration else { return nil }
        let landing = loadedRowsLanding
        loadedRowsSearch = nil
        if isAwaitingLoadedRows { isAwaitingLoadedRows = false }
        loadedRowsLanding = Landing()
        loadedRowsGeneration &+= 1
        return landing
    }

    func deferStep(forward: Bool) {
        loadedRowsLanding.steps += forward ? 1 : -1
    }

    func cancelLoadedRowsSearch() {
        loadedRowsSearch?.cancel()
        loadedRowsSearch = nil
        // @Published fires on every write, so skip the redraw when nothing changes.
        if isAwaitingLoadedRows { isAwaitingLoadedRows = false }
        loadedRowsGeneration &+= 1
        loadedRowsLanding = Landing()
    }

    // MARK: - Whole-dataset search

    // The search hands this generation back when it finishes; any later start or cancel makes it stale.
    func beginDatasetSearch(_ query: GridDatasetFindQuery?, clearsResults: Bool) -> Int {
        cancelDatasetSearch()
        cancelLoadedRowsSearch()
        datasetQuery = query
        searchStopped = false
        problem = nil
        loadedRowsBasis = nil
        if clearsResults {
            matches = []
            currentIndex = nil
        }
        return datasetGeneration
    }

    func attachDatasetSearch(_ task: Task<Void, Never>, generation: Int) {
        guard generation == datasetGeneration else {
            task.cancel()
            return
        }
        datasetSearch = task
        isSearching = true
    }

    // A change the owner reports waits for the owner to finish it; a later change replaces the wait.
    func deferDatasetSearch(_ task: Task<Void, Never>) {
        datasetSearch?.cancel()
        datasetGeneration &+= 1
        datasetSearch = task
    }

    func isCurrentDatasetSearch(_ generation: Int) -> Bool {
        generation == datasetGeneration
    }

    func finishDatasetSearch(_ found: [Match], current: Int?, generation: Int) {
        guard generation == datasetGeneration else { return }
        datasetSearch = nil
        isSearching = false
        setResults(found, current: current, problem: nil)
    }

    func abandonDatasetSearch(generation: Int) {
        guard generation == datasetGeneration else { return }
        datasetSearch = nil
        isSearching = false
        searchStopped = true
    }

    func stopDatasetSearch() {
        guard datasetSearch != nil else { return }
        cancelDatasetSearch()
        searchStopped = true
    }

    func cancelDatasetSearch() {
        datasetSearch?.cancel()
        datasetSearch = nil
        datasetGeneration &+= 1
        isSearching = false
    }
}
