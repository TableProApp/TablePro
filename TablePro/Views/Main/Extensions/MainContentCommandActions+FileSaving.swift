//
//  MainContentCommandActions+FileSaving.swift
//  TablePro
//

import AppKit
import Foundation
import os

/// Writing a query tab back to the `.sql` file it came from, and the conflict check that guards it.
///
/// A batch close needs the same write per victim, so the write is separated from the selected-tab
/// command that used to own it: the fire-and-forget version reports success before the file has
/// been written, and its failure path opens Save As for whichever tab is on screen, which is the
/// wrong tab for a victim that is not.
extension MainContentCommandActions {
    nonisolated private static let fileLogger = Logger(subsystem: "com.TablePro", category: "MainContentCommandActions")

    func saveFileToSourceURL() {
        Task { await saveSelectedFileAwaiting() }
    }

    @discardableResult
    func saveSelectedFileAwaiting() async -> Bool {
        guard let tab = coordinator?.tabManager.selectedTab,
              let url = tab.content.sourceFileURL else { return true }

        guard let change = FileTabBaseline.diskChange(in: tab.content) else {
            return await writeOrSaveAs(tabId: tab.id, content: tab.content.query, to: url)
        }

        coordinator?.tabManager.mutate(tabId: tab.id) { FileTabBaseline.showDiskChange(change, in: &$0.content) }
        switch change {
        case .missing:
            Self.fileLogger.info("Save of a file no longer on disk went to Save As: \(url.lastPathComponent, privacy: .private(mask: .hash))")
            return await saveFileAsAwaiting()
        case .modified:
            requestConflictResolution(tab: tab, url: url)
            return false
        }
    }

    func writeTabContent(tabId: UUID, content: String, to url: URL) {
        Task { await writeOrSaveAs(tabId: tabId, content: content, to: url) }
    }

    @discardableResult
    private func writeOrSaveAs(tabId: UUID, content: String, to url: URL) async -> Bool {
        do {
            try await writeSourceFile(tabId: tabId, content: content, to: url)
            return true
        } catch let error as FileTextWriter.WriteError {
            Self.fileLogger.info(
                "Save refused text the file's encoding cannot represent: \(url.lastPathComponent, privacy: .private(mask: .hash))"
            )
            reportFileSaveFailures([Self.saveFailureMessage(for: error, fileName: url.lastPathComponent)])
            return false
        } catch {
            Self.fileLogger.error("Failed to save file: \(error.publicLogShape, privacy: .public)")
            return await saveFileAsAwaiting()
        }
    }

    /// Each victim's file, for a batch close. A file whose copy on disk moved under the tab is left
    /// alone: resolving that needs the conflict sheet, which is a single window-level slot with no
    /// queue, so the batch keeps the tab open and the user answers it there.
    func saveFiles(_ targets: [(tab: QueryTab, url: URL)]) async -> Set<UUID> {
        var saved: Set<UUID> = []
        var failures: [String] = []
        for target in targets {
            if let change = FileTabBaseline.diskChange(in: target.tab.content) {
                Self.fileLogger.info(
                    "Batch save skipped a file changed on disk: \(target.url.lastPathComponent, privacy: .private(mask: .hash))"
                )
                coordinator?.tabManager.mutate(tabId: target.tab.id) {
                    FileTabBaseline.showDiskChange(change, in: &$0.content)
                }
                continue
            }
            do {
                try await writeSourceFile(tabId: target.tab.id, content: target.tab.content.query, to: target.url)
                saved.insert(target.tab.id)
            } catch {
                Self.fileLogger.error("Batch save failed to write a file: \(error.publicLogShape, privacy: .public)")
                failures.append(Self.saveFailureMessage(for: error, fileName: target.url.lastPathComponent))
            }
        }
        reportFileSaveFailures(failures)
        return saved
    }

    func reportFileSaveFailures(_ messages: [String]) {
        guard !messages.isEmpty else { return }
        let title = messages.count == 1
            ? String(localized: "Couldn't Save File")
            : String(localized: "Couldn't Save Files")
        coordinator?.presentError(title, messages.joined(separator: "\n\n"), closeAnchorWindow)
    }

    static func saveFailureMessage(for error: Error, fileName: String) -> String {
        guard case FileTextWriter.WriteError.unrepresentable(let encoding) = error else {
            return String(
                format: String(localized: "“%1$@” could not be written. %2$@"),
                fileName,
                error.localizedDescription
            )
        }
        return String(
            format: String(
                localized: """
                “%1$@” is encoded as %2$@, which can't represent some of the text in its tab. \
                The file was not changed. Use Save As to save the text as UTF-8.
                """
            ),
            fileName,
            encoding.displayName
        )
    }

    private func writeSourceFile(tabId: UUID, content: String, to url: URL) async throws {
        let encoding = await sourceFileEncoding(ofTab: tabId, at: url)
        try await SQLFileService.writeFile(content: content, to: url, encoding: encoding)
        coordinator?.tabManager.mutate(tabId: tabId) { tab in
            FileTabBaseline.recordWrite(of: content, to: url, as: encoding, in: &tab.content)
        }
    }

    private func sourceFileEncoding(ofTab tabId: UUID, at url: URL) async -> FileTextEncoding {
        if let recorded = coordinator?.tabManager.tabs.first(where: { $0.id == tabId })?.content.sourceFileEncoding {
            return recorded
        }
        return await SQLFileService.encodingOnDisk(of: url) ?? .utf8
    }

    private func requestConflictResolution(tab: QueryTab, url: URL) {
        let mineContent = tab.content.query
        let diskContent = FileTextLoader.load(url)?.content ?? ""
        coordinator?.fileConflictRequest = MainContentCoordinator.FileConflictRequest(
            tabId: tab.id,
            url: url,
            mineContent: mineContent,
            diskContent: diskContent
        )
    }

    func reloadFileFromDisk(tabId: UUID, url: URL) {
        guard let beforeIndex = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let queryAtRequestTime = coordinator?.tabManager.tabs[beforeIndex].content.query
        Task {
            guard let loaded = FileTextLoader.load(url) else { return }
            await MainActor.run {
                guard let index = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
                let liveQuery = coordinator?.tabManager.tabs[index].content.query
                guard liveQuery == queryAtRequestTime else { return }
                coordinator?.tabManager.mutate(at: index) { tab in
                    FileTabBaseline.adopt(loaded, into: &tab.content)
                }
            }
        }
    }
}
