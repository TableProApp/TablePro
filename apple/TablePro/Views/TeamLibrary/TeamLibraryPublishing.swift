//
//  TeamLibraryPublishing.swift
//  TablePro
//

import AppKit

internal enum TeamLibraryPublishOutcome: Equatable {
    case declined
    case finished(TeamLibraryPublishResult)
    case failed(TeamLibraryPublishError)
}

// What the welcome window and the Favorites sidebar say once a publish to the team library ends.
internal enum TeamLibraryPublishing {
    struct Message: Equatable {
        let title: String
        let text: String
        let isError: Bool
    }

    static func message(for result: TeamLibraryPublishResult, itemCount: Int, kind: Kind) -> Message? {
        switch result {
        case .published, .unchanged:
            return Message(title: String(localized: "Published to the team library"), text: kind.publishedText(itemCount), isError: false)
        case .conflicts:
            return nil
        case .queued(let failure):
            return Message(
                title: String(localized: "Not published yet"),
                text: String(format: String(localized: "%@ TablePro publishes your changes once the team library answers again."), failureText(failure)),
                isError: false
            )
        }
    }

    static func message(for error: TeamLibraryPublishError) -> Message {
        switch error {
        case .notWritable:
            return Message(
                title: String(localized: "Couldn't publish to the team library"),
                text: String(localized: "Only the team's owner and admins publish to its library."),
                isError: true
            )
        case .failed(let failure):
            return Message(
                title: String(localized: "Couldn't publish to the team library"),
                text: failureText(failure),
                isError: true
            )
        }
    }

    static func failureText(_ failure: TeamLibraryFailure) -> String {
        switch failure {
        case .offline:
            return String(localized: "TablePro couldn't reach the team library.")
        case .rateLimited:
            return String(localized: "The team library is busy right now.")
        case .server:
            return String(localized: "The team library had a problem on its side.")
        case .signedOut:
            return String(localized: "Sign in again to sync the team library.")
        case .unreadable:
            return String(localized: "Your account no longer has a seat in this team's library.")
        case .writeForbidden:
            return String(localized: "Only the team's owner and admins publish to its library.")
        case .cursorExpired:
            return String(localized: "The team library asked TablePro to download it again.")
        case .refused(let item?):
            return String(
                format: String(localized: "The team library refused “%@”. It may be too large or hold a field the library never stores."),
                item
            )
        case .refused(nil):
            return String(localized: "The team library refused the change. It may be too large or hold a field the library never stores.")
        }
    }

    enum Kind {
        case connections
        case savedQueries

        func publishedText(_ count: Int) -> String {
            switch self {
            case .connections:
                return String(
                    format: String(localized: "Your team can now see %d shared connections. Passwords were not included."),
                    count
                )
            case .savedQueries:
                return String(format: String(localized: "Published %d saved queries to your team."), count)
            }
        }
    }

    @MainActor
    static func present(_ message: Message, in window: NSWindow? = nil) {
        if message.isError {
            AlertHelper.showErrorSheet(title: message.title, message: message.text, window: window)
        } else {
            AlertHelper.showInfoSheet(title: message.title, message: message.text, window: window)
        }
    }

    @MainActor
    static func present(
        _ outcome: TeamLibraryPublishOutcome,
        itemCount: Int,
        kind: Kind,
        showConflicts: () -> Void
    ) {
        switch outcome {
        case .declined:
            return
        case .finished(.conflicts):
            showConflicts()
        case .finished(let result):
            if let message = message(for: result, itemCount: itemCount, kind: kind) {
                present(message)
            }
        case .failed(let error):
            present(message(for: error))
        }
    }
}
