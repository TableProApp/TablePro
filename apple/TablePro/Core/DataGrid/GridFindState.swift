import Combine
import Foundation

@MainActor
final class GridFindState: ObservableObject {
    struct Options: Equatable {
        var matchesCase = false
        var matchesWholeWord = false
        var usesRegularExpression = false
        var columnScope: DataGridColumnID?
    }

    struct Match: Hashable {
        let rowID: RowID
        let columnID: DataGridColumnID
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

    weak var datasetFinder: (any DataGridDatasetFinding)?
    private(set) var datasetQuery: GridDatasetFindQuery?
    private(set) var datasetSearch: Task<Void, Never>?
    private var datasetGeneration = 0

    var currentMatch: Match? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    func setResults(_ matches: [Match], current: Int?, problem: String?) {
        self.matches = matches
        self.currentIndex = current.flatMap { matches.indices.contains($0) ? $0 : nil }
        self.problem = problem
    }

    func setCurrentIndex(_ index: Int?) {
        currentIndex = index.flatMap { matches.indices.contains($0) ? $0 : nil }
    }

    // The next match takes the removed one's place, wrapping to the first.
    func removeMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        matches.remove(at: index)
        currentIndex = matches.isEmpty ? nil : (index < matches.count ? index : 0)
    }

    func reset() {
        cancelDatasetSearch()
        datasetQuery = nil
        searchStopped = false
        term = ""
        replacement = ""
        matches = []
        currentIndex = nil
        problem = nil
    }

    // MARK: - Whole-dataset search

    // The search hands this generation back when it finishes; any later start or cancel makes it stale.
    func beginDatasetSearch(_ query: GridDatasetFindQuery?, clearsResults: Bool) -> Int {
        cancelDatasetSearch()
        datasetQuery = query
        searchStopped = false
        problem = nil
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
