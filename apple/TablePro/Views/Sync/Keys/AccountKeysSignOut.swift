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
    // False when the person keeps the sign-in after the keys could not be erased, or when the sign-in it ran for ended,
    // which `isCurrent` answers before each try.
    var signOut: @MainActor (_ isCurrent: @escaping @MainActor () -> Bool) async -> Bool

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
            signOut: { isCurrent in
                // Every try goes to the one service the first reached: it stays bound to the sign-in it opened under, so
                // a retry after another sign-in never erases that one's keys.
                var bound: (any AccountKeyFlows)?
                while isCurrent() {
                    do {
                        let service: any AccountKeyFlows
                        if let bound {
                            service = bound
                        } else {
                            service = try await flows()
                            guard isCurrent() else { return false }
                            bound = service
                        }
                        // The core decides whether anything is there to erase, whatever the key state reads.
                        let outcome = try await service.signOutKeys()
                        logger.notice("Signed out of the keys: \(String(describing: outcome), privacy: .public)")
                        return true
                    } catch where isUnfilled(error) {
                        // No key engine runs on this service, so it never made a key device here to erase.
                        logger.notice("No key engine to sign out of on this service")
                        return true
                    } catch {
                        logger.warning(
                            "The keys' sign-out failed: \(LogRedaction.publicDescription(of: error), privacy: .public)"
                        )
                        switch await askAfterFailure(AccountKeysText.message(for: error)) {
                        case .retry: continue
                        case .signOutAnyway: return isCurrent()
                        case .cancel: return false
                        }
                    }
                }
                return false
            }
        )
    }

    private static func isUnfilled(_ error: any Error) -> Bool {
        guard case .Failed(let info)? = error as? CoreError else { return false }
        return info.code == "sync.unimplemented"
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
