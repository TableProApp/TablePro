//
//  AccountKeysSignOut.swift
//  TablePro
//

import AppKit
import Foundation
import os
import TableProFFI
import TableProLogRedaction

internal enum AccountKeysSignOutAnswer: Equatable {
    case retry
    case signOutAnyway
    case cancel
}

// Sign Out's part for the keys (core ADR 0056, Sign Out): before the sign-in is revoked, the device's own key device
// is revoked and its keys erased. Offline the core erases anyway; when it could not erase, the person decides.
@MainActor
internal struct AccountKeysSignOut {
    private static let logger = Logger(subsystem: "com.TablePro", category: "AccountKeys")

    // Whether this Mac holds keys that Sign Out erases, for the question it asks first.
    var holdsKeys: @MainActor () async -> Bool
    // False when the person keeps the sign-in after the keys could not be erased.
    var signOut: @MainActor () async -> Bool

    static var live: AccountKeysSignOut {
        over(AccountKeysEnvironment.liveFlows, askAfterFailure: AccountKeysSignOutPrompt.askAfterFailure)
    }

    static func over(
        _ flows: @escaping @MainActor () async throws -> any AccountKeyFlows,
        askAfterFailure: @escaping @MainActor (String) async -> AccountKeysSignOutAnswer
    ) -> AccountKeysSignOut {
        AccountKeysSignOut(
            holdsKeys: {
                switch try? await flows().keyState() {
                case .approved?, .locked?: true
                default: false
                }
            },
            signOut: {
                while true {
                    do {
                        let flows = try await flows()
                        // An account with no keys, or a Mac that cannot hold them, has no key device to revoke.
                        switch try? await flows.keyState() {
                        case .noKeys?, .noDeviceStore?:
                            return true
                        default:
                            break
                        }
                        let outcome = try await flows.signOutKeys()
                        logger.notice("Signed out of the keys: \(String(describing: outcome), privacy: .public)")
                        return true
                    } catch {
                        logger.warning(
                            "The keys' sign-out failed: \(LogRedaction.publicDescription(of: error), privacy: .public)"
                        )
                        switch await askAfterFailure(AccountKeysText.message(for: error)) {
                        case .retry: continue
                        case .signOutAnyway: return true
                        case .cancel: return false
                        }
                    }
                }
            }
        )
    }
}

@MainActor
internal enum AccountKeysSignOutPrompt {
    static func askAfterFailure(_ reason: String) async -> AccountKeysSignOutAnswer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "This Mac's encryption keys weren't erased")
        alert.informativeText = String(
            format: String(localized: "%@ If you sign out anyway, the keys stay on this Mac until another account signs in here."),
            reason
        )
        alert.addButton(withTitle: String(localized: "Try Again"))
        alert.addButton(withTitle: String(localized: "Sign Out Anyway")).hasDestructiveAction = true
        _ = AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        let answers: [AccountKeysSignOutAnswer] = [.retry, .signOutAnyway]
        let response = await AlertHelper.response(to: alert, in: nil)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return answers.indices.contains(index) ? answers[index] : .cancel
    }
}
