import Foundation
import TableProImport

internal struct ImportOutcomeMessage: Equatable {
    let title: String
    let message: String

    init(_ outcome: ImportOutcome) {
        let text = Self.text(for: outcome)
        title = text.title
        message = text.message
    }

    private static func text(for outcome: ImportOutcome) -> (title: String, message: String) {
        let connections = outcome.connectionsAdded + outcome.connectionsReplaced
        let failedTitle = String(localized: "Import Failed")
        switch outcome.failure {
        case .libraryUnreadable:
            return (failedTitle, String(localized: "TablePro could not read your connection library, so nothing was imported."))
        case .connectionsNotSaved:
            return (failedTitle, String(localized: "The connections could not be saved."))
        case .savedQueriesNotSaved:
            let queriesFailed = String(localized: "The saved queries could not be saved.")
            guard let imported = connectionSentence(connections) else {
                return (failedTitle, queriesFailed)
            }
            return (String(localized: "Import Incomplete"), "\(imported) \(queriesFailed)")
        case nil:
            break
        }

        let imported = [connectionSentence(connections), addedSentence(outcome.savedQueriesAdded)].compactMap { $0 }
        guard !imported.isEmpty else {
            return (
                String(localized: "Nothing Imported"),
                String(localized: "Everything selected was already in your library.")
            )
        }
        let sentences = imported + [notImportedSentence(outcome.savedQueriesNotImported)].compactMap { $0 }
        return (String(localized: "Import Complete"), sentences.joined(separator: " "))
    }

    private static func connectionSentence(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 connection was imported.")
            : String(format: String(localized: "%d connections were imported."), count)
    }

    private static func addedSentence(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 saved query was added.")
            : String(format: String(localized: "%d saved queries were added."), count)
    }

    private static func notImportedSentence(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1
            ? String(localized: "1 saved query was not imported.")
            : String(format: String(localized: "%d saved queries were not imported."), count)
    }
}
