//
//  VersionHistoryFormatting.swift
//  TablePro
//

import Foundation

internal enum VersionHistoryFormatting {
    static func title(for entry: VersionHistoryEntry) -> String {
        if entry.isCurrent {
            return String(localized: "Current Version")
        }
        if let summary = entry.summary, !summary.isBlank {
            return summary
        }
        return dateText(for: entry) ?? String(localized: "Earlier Version")
    }

    static func subtitle(for entry: VersionHistoryEntry) -> String {
        var parts: [String] = []
        if entry.isCurrent, entry.hasUncommittedChanges {
            parts.append(String(localized: "Uncommitted changes"))
        }
        if let author = entry.author, !author.isBlank {
            parts.append(author)
        }
        let showsDateInTitle = !entry.isCurrent && (entry.summary ?? "").isBlank
        if !showsDateInTitle, let date = dateText(for: entry) {
            parts.append(date)
        }
        if let revision = entry.reference.shortRevision {
            parts.append(revision)
        }
        return parts.joined(separator: " · ")
    }

    static func rowSubtitle(for entry: VersionHistoryEntry) -> String {
        var parts: [String] = []
        if entry.isCurrent, entry.hasUncommittedChanges {
            parts.append(String(localized: "Uncommitted changes"))
        }
        if let author = entry.author, !author.isBlank {
            parts.append(author)
        }
        let showsDateInTitle = !entry.isCurrent && (entry.summary ?? "").isBlank
        if !showsDateInTitle, let date = entry.date {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.joined(separator: " · ")
    }

    static func shortLabel(for entry: VersionHistoryEntry) -> String {
        if entry.isCurrent {
            return String(localized: "Current Version")
        }
        if let revision = entry.reference.shortRevision {
            return revision
        }
        return dateText(for: entry) ?? String(localized: "Earlier Version")
    }

    static func accessibilityLabel(for entry: VersionHistoryEntry) -> String {
        let subtitle = subtitle(for: entry)
        guard !subtitle.isEmpty else { return title(for: entry) }
        return String(format: String(localized: "%@, %@"), title(for: entry), subtitle)
    }

    static func noticeText(_ notice: VersionHistoryNotice) -> String {
        switch notice {
        case .keepsLatestVersions(let count):
            return String(format: String(localized: "Keeps the last %d versions on this Mac."), count)
        case .showsLatestCommits(let count):
            return String(format: String(localized: "Showing the %d most recent commits."), count)
        }
    }

    private static func dateText(for entry: VersionHistoryEntry) -> String? {
        entry.date?.formatted(date: .abbreviated, time: .shortened)
    }
}
