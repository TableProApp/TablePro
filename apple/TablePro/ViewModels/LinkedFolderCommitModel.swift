//
//  LinkedFolderCommitModel.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProUtilities

internal enum LinkedFolderCommitDiff: Equatable, Sendable {
    case loading
    case comparison(VersionComparison)
    case binary
    case unavailable(String)
}

internal enum LinkedFolderCommitDiffLoader {
    static let byteLimit = 4 * 1_024 * 1_024
    static let binaryProbeLength = 8_000

    @concurrent
    static func load(
        _ entry: LinkedFolderCommitEntry,
        topLevel: URL,
        hasHead: Bool,
        client: GitClient
    ) async -> LinkedFolderCommitDiff {
        let fileURL = topLevel.appendingPathComponent(entry.path)
        // Git stores a symbolic link as the path it points to, never the file behind it.
        let linkTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
        var current = Data()
        if let linkTarget {
            current = Data(linkTarget.utf8)
        } else if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                current = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            } catch {
                return .unavailable(error.localizedDescription)
            }
        }
        var baseline = Data()
        if hasHead, !entry.isNewFile {
            do {
                baseline = try await client.blob(revision: "HEAD", path: entry.comparedPath, in: topLevel)
            } catch {
                let failure = LinkedFolderGitError(error)
                return .unavailable(failure?.output ?? failure?.errorDescription ?? error.localizedDescription)
            }
        }
        guard baseline.count <= byteLimit, current.count <= byteLimit else { return .comparison(.tooLarge) }
        guard !isBinary(baseline), !isBinary(current) else { return .binary }

        let loaded = current.isEmpty || linkTarget != nil ? nil : FileTextLoader.load(fileURL)
        guard let before = FileTextLoader.decode(baseline, declaredEncoding: loaded?.encoding) else { return .binary }
        let after = linkTarget ?? loaded?.content ?? ""
        return .comparison(VersionComparison.compare(baseline: before, current: after))
    }

    static func isBinary(_ data: Data) -> Bool {
        ByteOrderMark.leading(data) == nil
            && data.prefix(binaryProbeLength).contains(0)
            && FileTextLoader.unmarkedWideEncoding(of: data) == nil
    }
}

@MainActor
internal final class LinkedFolderCommitModel: ObservableObject {
    internal enum Phase: Equatable {
        case loading
        case ready
        case committing
        case loadFailed(String)
    }

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedFolderCommit")

    @Published private(set) var phase: Phase = .loading
    @Published var draft = LinkedFolderCommitDraft(records: [], prefix: "")
    @Published private(set) var selection: String?
    @Published private(set) var diff: LinkedFolderCommitDiff = .loading
    @Published private(set) var branch: String?
    @Published private(set) var commitError: LinkedFolderGitError?
    @Published private(set) var unsavedPaths: Set<String> = []

    let folder: LinkedSQLFolder
    let preselectedPath: String?

    private let clientFactory: @Sendable () -> GitClient?
    private let actions: LinkedFolderGitActions
    private var repository: GitRepositoryInfo?
    private var hasHead = false
    private var diffTask: Task<Void, Never>?
    private var commitTask: Task<Bool, Never>?

    init(
        folder: LinkedSQLFolder,
        preselectedPath: String? = nil,
        clientFactory: @escaping @Sendable () -> GitClient? = { GitClient.make() },
        actions: LinkedFolderGitActions = .shared
    ) {
        self.folder = folder
        self.preselectedPath = preselectedPath
        self.clientFactory = clientFactory
        self.actions = actions
    }

    var selectedEntry: LinkedFolderCommitEntry? {
        draft.entries.first { $0.id == selection }
    }

    var isBusy: Bool {
        guard let topLevel = repository?.topLevel else { return false }
        return actions.operations[topLevel] != nil
    }

    var canCommit: Bool {
        phase == .ready && draft.canCommit && !isBusy
    }

    func load() async {
        guard phase != .ready, phase != .committing else { return }
        phase = .loading
        guard let client = clientFactory() else {
            phase = .loadFailed(LinkedFolderGitError.gitUnavailable.errorDescription ?? "")
            return
        }
        let directory = folder.expandedURL
        do {
            guard let repository = try await client.repositoryInfo(in: directory) else {
                phase = .loadFailed(LinkedFolderGitError.notInRepository.errorDescription ?? "")
                return
            }
            let records = try await client.status(in: directory)
            hasHead = try await client.headCommit(in: repository.topLevel) != nil
            branch = try await client.currentBranch(in: repository.topLevel)
            self.repository = repository
            draft = LinkedFolderCommitDraft(records: records, prefix: repository.prefix, preselecting: preselectedPath)
            unsavedPaths = Self.unsavedPaths(in: repository.topLevel, among: draft.entries)
            phase = .ready
            let preselected = draft.entries.first { $0.folderRelativePath == preselectedPath }
            select((preselected ?? draft.entries.first)?.id)
        } catch {
            Self.logger.error("Loading the commit sheet failed: \(error.publicLogShape, privacy: .public)")
            let failure = LinkedFolderGitError(error)
            phase = .loadFailed(failure?.output ?? failure?.errorDescription ?? error.localizedDescription)
        }
    }

    func select(_ id: String?) {
        guard id != selection else { return }
        selection = id
        diffTask?.cancel()
        guard let entry = selectedEntry, let repository, let client = clientFactory() else {
            diff = .loading
            return
        }
        diff = .loading
        let hasHead = hasHead
        diffTask = Task { [weak self] in
            let loaded = await LinkedFolderCommitDiffLoader.load(
                entry,
                topLevel: repository.topLevel,
                hasHead: hasHead,
                client: client
            )
            guard !Task.isCancelled, self?.selection == entry.id else { return }
            self?.diff = loaded
        }
    }

    func setChecked(_ entry: LinkedFolderCommitEntry, _ isChecked: Bool) {
        draft.setChecked(entry, isChecked)
    }

    func commit() async -> Bool {
        guard canCommit, let repository else { return false }
        phase = .committing
        commitError = nil
        let draft = draft
        let actions = actions
        let task = Task { @MainActor in
            do {
                try await actions.commit(draft, in: repository)
                return true
            } catch {
                Self.logger.error("Commit failed: \(error.publicLogShape, privacy: .public)")
                self.commitError = LinkedFolderGitError(error)
                return false
            }
        }
        commitTask = task
        let committed = await task.value
        commitTask = nil
        if !committed { phase = .ready }
        return committed
    }

    // Ends a running hook or a commit that hangs, the way Control-C would in Terminal.
    func cancel() {
        diffTask?.cancel()
        commitTask?.cancel()
    }

    private static func unsavedPaths(in topLevel: URL, among entries: [LinkedFolderCommitEntry]) -> Set<String> {
        let byURL = Dictionary(
            entries.map { (topLevel.appendingPathComponent($0.path).resolvingSymlinksInPath().path, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var paths: Set<String> = []
        for coordinator in MainContentCoordinator.activeCoordinators.values {
            for tab in coordinator.tabManager.tabs where tab.content.isFileDirty {
                guard let url = tab.content.sourceFileURL, let id = byURL[url.resolvingSymlinksInPath().path] else { continue }
                paths.insert(id)
            }
        }
        return paths
    }
}
