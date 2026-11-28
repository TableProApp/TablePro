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

    // A publish that went through says nothing: the section shows the items once the pull after the push lands.
    static func message(for result: TeamLibraryPublishResult) -> Message? {
        switch result {
        case .published, .unchanged, .conflicts:
            return nil
        case .publishedWithoutPasswords(_, let leftOut):
            return Message(
                title: String(localized: "Published without passwords"),
                text: passwordsText(leftOut),
                isError: false
            )
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
                text: String(localized: "Only the team's owner, admins and editors publish to its library."),
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

    static func passwordsText(_ leftOut: TeamPasswordsLeftOut) -> String {
        switch leftOut {
        case .off:
            return String(localized: "Your team doesn't sync passwords, so teammates enter their own.")
        case .notConfirmed:
            return String(localized: "Passwords go to the team once an owner or admin confirms your keys. Publish again after that.")
        case .rotationDue:
            return String(localized: "The team's key is being replaced, so passwords wait. Publish again in a moment.")
        case .role:
            return String(localized: "Your role in this team doesn't share passwords.")
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
            return String(localized: "Only the team's owner, admins and editors publish to its library.")
        case .licenseExpired:
            return String(localized: "The server's TablePro license has expired, so it takes no changes. They stay on this Mac until your administrator renews the license.")
        case .refused:
            return String(localized: "The team library refused the change. It may be too large or hold a field the library never stores.")
        case .deletePending:
            return String(localized: "TablePro is still deleting the Team Library data of the last account on this Mac. Team Library stays off until it is gone.")
        case .unavailable:
            return String(localized: "Team Library isn't available on this Mac right now.")
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
    static func present(_ outcome: TeamLibraryPublishOutcome, showConflicts: () -> Void) {
        switch outcome {
        case .declined:
            return
        case .finished(.conflicts):
            showConflicts()
        case .finished(let result):
            if let message = message(for: result) {
                present(message)
            }
        case .failed(let error):
            present(message(for: error))
        }
    }
}
