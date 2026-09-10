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
        guard let tab = coordinator?.tabManager.selectedTab,
              let url = tab.content.sourceFileURL else { return }

        if isExternallyModified(tab: tab, url: url) {
            requestConflictResolution(tab: tab, url: url)
            return
        }

        writeTabContent(tabId: tab.id, content: tab.content.query, to: url)
    }

    func writeTabContent(tabId: UUID, content: String, to url: URL) {
        Task {
            guard await writeTabContentAwaiting(tabId: tabId, content: content, to: url) else {
                saveFileAs()
                return
            }
        }
    }

    /// The write itself, awaited and answering whether it landed.
    ///
    /// A batch close has to know: `writeTabContent` starts a detached Task and returns, so a caller
    /// that closed the tab on its say-so closed it before the write had happened or failed. Its
    /// failure path is the selected tab's Save As panel, which is also wrong for a victim that is
    /// not the tab on screen, so the batch takes this instead and keeps a failed victim open.
    @discardableResult
    func writeTabContentAwaiting(tabId: UUID, content: String, to url: URL) async -> Bool {
        do {
            try await SQLFileService.writeFile(content: content, to: url)
            let mtime = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            coordinator?.tabManager.mutate(tabId: tabId) { tab in
                tab.content.savedFileContent = content
                tab.content.loadMtime = mtime
                tab.content.externalModificationDetected = false
            }
            return true
        } catch {
            Self.fileLogger.error("Failed to save file: \(error.localizedDescription)")
            return false
        }
    }

    /// One victim's file, for a batch close. A file whose copy on disk moved under the tab is left
    /// alone: resolving that needs the conflict sheet, which is a single window-level slot with no
    /// queue, so the batch keeps the tab open and the user answers it there.
    func saveFile(of tab: QueryTab, to url: URL) async -> Bool {
        guard !isExternallyModified(tab: tab, url: url) else {
            Self.fileLogger.info("Batch save skipped a file changed on disk: \(url.lastPathComponent, privacy: .public)")
            return false
        }
        return await writeTabContentAwaiting(tabId: tab.id, content: tab.content.query, to: url)
    }

    func isExternallyModified(tab: QueryTab, url: URL) -> Bool {
        guard let loadMtime = tab.content.loadMtime,
              let currentMtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else {
            return false
        }
        return currentMtime > loadMtime.addingTimeInterval(0.5)
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
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            await MainActor.run {
                guard let index = coordinator?.tabManager.tabs.firstIndex(where: { $0.id == tabId }) else { return }
                let liveQuery = coordinator?.tabManager.tabs[index].content.query
                guard liveQuery == queryAtRequestTime else { return }
                coordinator?.tabManager.mutate(at: index) { tab in
                    tab.content.query = loaded.content
                    tab.content.savedFileContent = loaded.content
                    tab.content.loadMtime = mtime
                    tab.content.externalModificationDetected = false
                }
            }
        }
    }
}
