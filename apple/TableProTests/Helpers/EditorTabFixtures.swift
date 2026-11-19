//
//  EditorTabFixtures.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro

@MainActor
internal final class EditorTabCommandRecorder {
    var activated: [UUID] = []
    var kept: [UUID] = []
    var closed: [UUID] = []
    var movedToConnection: [UUID] = []
    var pinned: [(UUID, Bool)] = []
    var renameRequests: [UUID] = []
    var renamed: [(UUID, String)] = []
    var tornOff: [(UUID, NSPoint?)] = []
    var newTabCount = 0
}

extension EditorTabCommands {
    @MainActor
    internal static func stub(
        recorder: EditorTabCommandRecorder = EditorTabCommandRecorder(),
        connectionId: UUID = UUID(),
        isPinned: Bool = false,
        canRename: Bool = false,
        renameSeed: @escaping (UUID) -> EditorTabRenameSeed? = { _ in nil },
        canCloseOthers: Bool = true,
        canCloseAll: Bool = true,
        canTearOff: Bool = true,
        offersMoveToConnection: Bool = false,
        canMoveToConnection: Bool = false
    ) -> EditorTabCommands {
        EditorTabCommands(
            connectionId: connectionId,
            activate: { recorder.activated.append($0) },
            newTab: { recorder.newTabCount += 1 },
            keepOpen: { recorder.kept.append($0) },
            canKeepOpen: { _ in false },
            isPinned: { _ in isPinned },
            setPinned: { recorder.pinned.append(($0, $1)) },
            canRename: { _ in canRename },
            renameSeed: renameSeed,
            beginRename: { recorder.renameRequests.append($0) },
            // An emptied name goes back to the automatic one, as the model does.
            rename: { id, text in
                recorder.renamed.append((id, text))
                return text.isEmpty ? renameSeed(id)?.placeholder : text
            },
            close: { recorder.closed.append($0) },
            closeOthers: { _ in },
            canCloseOthers: { _ in canCloseOthers },
            closeAll: {},
            canCloseAll: { canCloseAll },
            moveTab: { _, _ in },
            canMove: { _, _ in true },
            moveBy: { _, _ in },
            tearOff: { recorder.tornOff.append(($0, $1)) },
            canTearOff: { _ in canTearOff },
            receiveTab: { _, _ in true },
            isOverTabStrip: { _ in false },
            moveToConnection: { recorder.movedToConnection.append($0) },
            offersMoveToConnection: { _ in offersMoveToConnection },
            canMoveToConnection: { _ in canMoveToConnection }
        )
    }
}

extension EditorTabItem {
    internal static func sample(
        id: UUID = UUID(),
        title: String = "Album",
        isSelected: Bool = false,
        isPinned: Bool = false,
        isPreview: Bool = false,
        status: EditorTabStatus = .idle,
        position: Int = 1,
        count: Int = 1
    ) -> EditorTabItem {
        EditorTabItem(
            id: id,
            title: title,
            tooltip: title,
            isSelected: isSelected,
            isPinned: isPinned,
            isPreview: isPreview,
            status: status,
            position: position,
            count: count
        )
    }

    internal static func samples(titles: [String], selected: Int? = 0) -> [EditorTabItem] {
        titles.enumerated().map { index, title in
            sample(title: title, isSelected: index == selected, position: index + 1, count: titles.count)
        }
    }
}
