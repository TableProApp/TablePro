//
//  VersionHistoryViewModelTests.swift
//  TableProTests
//

import Combine
import Foundation
import Testing

@testable import TablePro

private actor FakeVersionHistoryProvider: VersionHistoryProvider {
    var page: VersionHistoryPage
    var contents: [VersionHistoryReference: String]
    var loadError: VersionHistoryError?
    var isDirtyOnDisk: Bool
    private(set) var contentRequests: [VersionHistoryReference] = []
    private(set) var restored: [VersionHistoryReference] = []

    init(page: VersionHistoryPage, contents: [VersionHistoryReference: String]) {
        self.page = page
        self.contents = contents
        isDirtyOnDisk = page.current?.hasUncommittedChanges ?? false
    }

    func setDirtyOnDisk(_ isDirty: Bool) {
        isDirtyOnDisk = isDirty
    }

    func prepareRestore(_ reference: VersionHistoryReference) async throws -> VersionRestorePlan {
        let isDirty = isDirtyOnDisk
        return VersionRestorePlan(replacesUncommittedChanges: isDirty) { [self] in
            await self.recordRestore(reference)
        }
    }

    private func recordRestore(_ reference: VersionHistoryReference) {
        restored.append(reference)
        if let text = contents[reference] {
            contents[.current] = text
        }
    }

    func setLoadError(_ error: VersionHistoryError?) {
        loadError = error
    }

    func setCurrent(_ text: String) {
        contents[.current] = text
    }

    func loadHistory() async throws -> VersionHistoryPage {
        if let loadError { throw loadError }
        return page
    }

    func content(of reference: VersionHistoryReference) async throws -> String {
        contentRequests.append(reference)
        guard let content = contents[reference] else { throw VersionHistoryError.versionNotFound }
        return content
    }
}

@MainActor
@Suite("VersionHistoryViewModel")
struct VersionHistoryViewModelTests {
    private static let past = VersionHistoryReference.savedQueryVersion(id: 7)
    private static let older = VersionHistoryReference.savedQueryVersion(id: 3)

    private func makeProvider(uncommitted: Bool = false) -> FakeVersionHistoryProvider {
        FakeVersionHistoryProvider(
            page: VersionHistoryPage(entries: [
                VersionHistoryEntry(reference: .current, date: Date(timeIntervalSince1970: 300), hasUncommittedChanges: uncommitted),
                VersionHistoryEntry(reference: Self.past, date: Date(timeIntervalSince1970: 200)),
                VersionHistoryEntry(reference: Self.older, date: Date(timeIntervalSince1970: 100)),
            ]),
            contents: [
                .current: "SELECT 3\n",
                Self.past: "SELECT 2\n",
                Self.older: "SELECT 3\n",
            ]
        )
    }

    private func makeViewModel(_ provider: FakeVersionHistoryProvider) -> VersionHistoryViewModel {
        VersionHistoryViewModel(
            subject: .savedQuery(id: UUID()),
            provider: provider,
            refreshSignal: Empty().eraseToAnyPublisher()
        )
    }

    private func loadedDetail(_ viewModel: VersionHistoryViewModel) async throws -> VersionHistoryDetail {
        await viewModel.detailTask?.value
        guard case .loaded(let detail) = viewModel.detailState else {
            Issue.record("Detail did not load: \(viewModel.detailState)")
            throw VersionHistoryError.versionNotFound
        }
        return detail
    }

    @Test("Loading selects the current version and compares it with the version before it")
    func currentComparesWithPrevious() async throws {
        let viewModel = makeViewModel(makeProvider())

        await viewModel.loadList()
        let detail = try await loadedDetail(viewModel)

        #expect(viewModel.listState == .loaded)
        #expect(viewModel.selection == .current)
        #expect(detail.content == "SELECT 3\n")
        let comparison = try #require(detail.comparison)
        #expect(comparison.older.reference == Self.past)
        #expect(comparison.newer.reference == .current)
        guard case .differs(let pairs) = comparison.outcome else {
            Issue.record("Expected a difference")
            return
        }
        #expect(pairs.contains { $0.before == "SELECT 2" && $0.after == "SELECT 3" })
    }

    @Test("A past version is compared with the current one, older side first")
    func pastComparesWithCurrent() async throws {
        let viewModel = makeViewModel(makeProvider())
        await viewModel.loadList()
        await viewModel.detailTask?.value

        viewModel.selection = Self.older
        let detail = try await loadedDetail(viewModel)

        #expect(detail.content == "SELECT 3\n")
        let comparison = try #require(detail.comparison)
        #expect(comparison.older.reference == Self.older)
        #expect(comparison.newer.reference == .current)
        #expect(comparison.outcome == .identical)
    }

    @Test("A past version is read once, the current text every time")
    func onlyPastContentIsCached() async throws {
        let provider = makeProvider()
        let viewModel = makeViewModel(provider)
        await viewModel.loadList()
        await viewModel.detailTask?.value
        await provider.setCurrent("SELECT 4\n")

        await viewModel.loadList()
        let detail = try await loadedDetail(viewModel)

        #expect(detail.content == "SELECT 4\n")
        let requests = await provider.contentRequests
        #expect(requests.filter { $0 == .current }.count == 2)
        #expect(requests.filter { $0 == Self.past }.count == 1)
    }

    @Test("Restoring with nothing unsaved needs no confirmation and selects the current version")
    func restoreWithoutUncommittedChanges() async throws {
        let provider = makeProvider()
        let viewModel = makeViewModel(provider)
        var asked = false
        var restoredCalls = 0
        viewModel.confirmReplacingUncommittedChanges = {
            asked = true
            return true
        }
        viewModel.onRestored = { restoredCalls += 1 }
        await viewModel.loadList()
        viewModel.selection = Self.past

        await viewModel.restore(try #require(viewModel.selectedEntry))

        #expect(!asked)
        #expect(restoredCalls == 1)
        #expect(await provider.restored == [Self.past])
        #expect(viewModel.selection == .current)
        #expect(!viewModel.isRestoring)
    }

    @Test("Restoring over uncommitted changes asks first, and a refusal changes nothing")
    func restoreOverUncommittedChangesAsks() async throws {
        let provider = makeProvider(uncommitted: true)
        let viewModel = makeViewModel(provider)
        viewModel.confirmReplacingUncommittedChanges = { false }
        await viewModel.loadList()
        let entry = try #require(viewModel.page.entries.first { $0.reference == Self.past })

        await viewModel.restore(entry)
        #expect(await provider.restored.isEmpty)

        viewModel.confirmReplacingUncommittedChanges = { true }
        await viewModel.restore(entry)
        #expect(await provider.restored == [Self.past])
    }

    @Test("A change made after the list loaded still asks before it is replaced")
    func restoreRechecksAtTheMomentOfWriting() async throws {
        let provider = makeProvider(uncommitted: false)
        let viewModel = makeViewModel(provider)
        var asked = false
        viewModel.confirmReplacingUncommittedChanges = {
            asked = true
            return false
        }
        await viewModel.loadList()
        await provider.setDirtyOnDisk(true)

        await viewModel.restore(try #require(viewModel.page.entries.first { $0.reference == Self.past }))

        #expect(asked)
        #expect(await provider.restored.isEmpty)
    }

    @Test("The current version cannot be restored")
    func currentIsNotRestorable() async throws {
        let provider = makeProvider()
        let viewModel = makeViewModel(provider)
        await viewModel.loadList()

        #expect(!viewModel.canRestoreSelection)
        await viewModel.restore(try #require(viewModel.page.current))
        #expect(await provider.restored.isEmpty)
    }

    @Test("A failed refresh keeps what is shown, but a subject that is gone clears it")
    func refreshFailures() async throws {
        let provider = makeProvider()
        let viewModel = makeViewModel(provider)
        await viewModel.loadList()
        await viewModel.detailTask?.value

        await provider.setLoadError(.commandFailed("git timed out"))
        await viewModel.loadList()
        #expect(viewModel.listState == .loaded)
        #expect(viewModel.page.entries.count == 3)

        await provider.setLoadError(.subjectNotFound)
        await viewModel.loadList()
        #expect(viewModel.page.entries.isEmpty)
        #expect(viewModel.listState == .failed(VersionHistoryError.subjectNotFound.localizedDescription))
    }
}

@Suite("VersionComparison")
struct VersionComparisonTests {
    @Test("Equal text is identical, different text is a line diff that keeps blank lines")
    func outcomes() {
        #expect(VersionComparison.compare(baseline: "a\n", current: "a\n") == .identical)
        guard case .differs(let pairs) = VersionComparison.compare(baseline: "a\n\nb", current: "a\nb") else {
            Issue.record("Expected a difference")
            return
        }
        #expect(pairs.contains { $0.kind == .removed && $0.before == "" })
    }

    @Test("Text that differs only in line endings is identical")
    func lineEndingsOnly() {
        #expect(VersionComparison.compare(baseline: "a\nb\n", current: "a\r\nb\r\n") == .identical)
    }

    @Test("Text past the line limit is not diffed")
    func tooLarge() {
        let big = Array(repeating: "x", count: VersionComparison.maximumLineCount + 1).joined(separator: "\n")
        #expect(VersionComparison.compare(baseline: big, current: big + "\ny") == .tooLarge)
    }
}

@Suite("VersionHistoryPage")
struct VersionHistoryPageTests {
    @Test("The current version's baseline is the newest past version, a past version's is the current one")
    func baselines() {
        let page = VersionHistoryPage(entries: [
            VersionHistoryEntry(reference: .current),
            VersionHistoryEntry(reference: .gitRevision(commit: "b", path: "q.sql")),
            VersionHistoryEntry(reference: .gitRevision(commit: "a", path: "q.sql")),
        ])
        #expect(page.baseline(for: .current)?.reference == .gitRevision(commit: "b", path: "q.sql"))
        #expect(page.baseline(for: .gitRevision(commit: "a", path: "q.sql"))?.reference == .current)
        #expect(VersionHistoryPage(entries: [VersionHistoryEntry(reference: .current)]).baseline(for: .current) == nil)
        #expect(VersionHistoryReference.gitRevision(commit: "0123456789", path: "q.sql").shortRevision == "0123456")
    }
}
