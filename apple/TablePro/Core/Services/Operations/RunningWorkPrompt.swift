//
//  RunningWorkPrompt.swift
//  TablePro
//

import Foundation

internal enum RunningWorkAction: Equatable, Sendable {
    case quit
    case relaunch
    case close
    case disconnect
}

internal struct RunningWorkPrompt: Equatable, Sendable {
    internal let title: String
    internal let message: String
    internal let confirmButton: String

    // Nil when nothing is running. Other losses ride along on the same alert, never ask on their own.
    internal static func make(
        action: RunningWorkAction,
        work: [RunningWork],
        otherLosses: [String] = []
    ) -> RunningWorkPrompt? {
        guard !work.isEmpty else { return nil }
        let lines = work.map(line(for:)) + otherLosses
        var paragraphs = [lines.joined(separator: "\n"), consequence(of: action)]
        paragraphs.append(contentsOf: notes(for: work))
        return RunningWorkPrompt(
            title: title(for: action),
            message: paragraphs.joined(separator: "\n\n"),
            confirmButton: confirmButton(for: action)
        )
    }

    // The save question carries the running work, so a close with both asks once.
    internal static func saveMessage(_ message: String, action: RunningWorkAction, alsoStopping work: [RunningWork]) -> String {
        guard !work.isEmpty else { return message }
        let lines = work.map(line(for:)).joined(separator: "\n")
        return ([message, lines, consequence(of: action)] + notes(for: work)).joined(separator: "\n\n")
    }

    internal static func line(for work: RunningWork) -> String {
        let subject = work.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let connection = work.connectionName
        switch work.kind {
        case .query:
            return String(format: String(localized: "Running query in “%1$@” on %2$@"), subject, connection)
        case .restore:
            return String(format: String(localized: "Restoring “%1$@” on %2$@"), subject, connection)
        case .backup:
            return String(format: String(localized: "Backing up “%1$@” on %2$@"), subject, connection)
        case .dataImport:
            guard !subject.isEmpty else { return String(format: String(localized: "Importing into %@"), connection) }
            return String(format: String(localized: "Importing “%1$@” into %2$@"), subject, connection)
        case .dataExport:
            guard !subject.isEmpty else { return String(format: String(localized: "Exporting from %@"), connection) }
            return String(format: String(localized: "Exporting “%1$@” from %2$@"), subject, connection)
        case .tableTransfer:
            return String(format: String(localized: "Transferring tables to %@"), subject)
        case .objectCopy:
            return String(format: String(localized: "Copying objects to %@"), subject)
        case .agentReply:
            guard !subject.isEmpty else { return String(format: String(localized: "Agent reply on %@"), connection) }
            return String(format: String(localized: "Agent reply “%1$@” on %2$@"), subject, connection)
        case .compareRun:
            return String(format: String(localized: "Comparing %1$@ with %2$@"), subject, connection)
        case .compareApply:
            return String(format: String(localized: "Applying a sync script to %@"), subject)
        }
    }

    private static func title(for action: RunningWorkAction) -> String {
        switch action {
        case .quit: return String(localized: "Quit while work is still running?")
        case .relaunch: return String(localized: "Relaunch while work is still running?")
        case .close: return String(localized: "Close while work is still running?")
        case .disconnect: return String(localized: "Disconnect while work is still running?")
        }
    }

    private static func consequence(of action: RunningWorkAction) -> String {
        switch action {
        case .quit, .relaunch: return String(localized: "Quitting stops this work.")
        case .close: return String(localized: "Closing stops this work.")
        case .disconnect: return String(localized: "Disconnecting stops this work.")
        }
    }

    private static func notes(for work: [RunningWork]) -> [String] {
        let kinds = Set(work.map(\.kind))
        var notes: [String] = []
        if kinds.contains(.restore) {
            notes.append(String(localized: "A stopped restore can leave the database partly restored."))
        }
        if kinds.contains(.compareApply) {
            notes.append(String(localized: "Statements a sync already ran stay applied."))
        }
        return notes
    }

    private static func confirmButton(for action: RunningWorkAction) -> String {
        switch action {
        case .quit: return String(localized: "Quit Anyway")
        case .relaunch: return String(localized: "Relaunch Anyway")
        case .close: return String(localized: "Close Anyway")
        case .disconnect: return String(localized: "Disconnect Anyway")
        }
    }
}
