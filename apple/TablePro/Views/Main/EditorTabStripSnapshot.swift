//
//  EditorTabStripSnapshot.swift
//  TablePro
//

import Foundation

internal enum EditorTabStatus: Equatable {
    case idle
    case running
    case finished
    case failed
}

internal struct EditorTabItem: Equatable, Identifiable {
    internal let id: UUID
    internal let title: String
    internal let tooltip: String
    internal let isSelected: Bool
    internal let isPinned: Bool
    internal let isPreview: Bool
    internal let status: EditorTabStatus
    internal let position: Int
    internal let count: Int

    // An assistive technology is told the string, never the italic face a preview is set in.
    internal var accessibilityDescription: String {
        var description = String(format: String(localized: "%1$d of %2$d"), position, count)
        if isPinned {
            description = String(format: String(localized: "%@, pinned"), description)
        }
        if isPreview {
            description = String(format: String(localized: "%@, preview tab"), description)
        }
        switch status {
        case .idle:
            return description
        case .running:
            return String(format: String(localized: "%@, running"), description)
        case .finished:
            return String(format: String(localized: "%@, finished"), description)
        case .failed:
            return String(format: String(localized: "%@, failed"), description)
        }
    }
}

internal enum EditorTabStripSnapshot {
    internal static func items(
        tabs: [QueryTab],
        selectedId: UUID?,
        target: ContainerSwitchTarget?,
        isBusy: (UUID) -> Bool
    ) -> [EditorTabItem] {
        let labels = EditorTabLabelResolver.resolve(tabs: tabs, target: target)
        return tabs.enumerated().map { index, tab in
            let label = labels[tab.id]
            let isSelected = tab.id == selectedId
            return EditorTabItem(
                id: tab.id,
                title: label?.text ?? tab.title,
                tooltip: tooltip(description: label?.description ?? tab.title, isPreview: tab.isPreview),
                isSelected: isSelected,
                isPinned: tab.isPinned,
                isPreview: tab.isPreview,
                status: status(of: tab, isSelected: isSelected, isBusy: isBusy(tab.id)),
                position: index + 1,
                count: tabs.count
            )
        }
    }

    private static func tooltip(description: String, isPreview: Bool) -> String {
        guard isPreview else { return description }
        return String(format: String(localized: "%@\nPreview tab. Double-click to keep it open."), description)
    }

    private static func status(of tab: QueryTab, isSelected: Bool, isBusy: Bool) -> EditorTabStatus {
        if isBusy { return .running }
        guard !isSelected, let outcome = tab.execution.unseenOutcome else { return .idle }
        return outcome == .failed ? .failed : .finished
    }
}
