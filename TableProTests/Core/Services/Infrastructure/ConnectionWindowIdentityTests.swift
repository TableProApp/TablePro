//
//  ConnectionWindowIdentityTests.swift
//  TableProTests
//
//  Session restore was gated on "no main window is open", using a predicate that
//  also matched the CSV/JSON inspector window, so an open inspector silently
//  stopped the last session from reopening.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Connection window identity")
struct ConnectionWindowIdentityTests {
    @Test("The document inspector is not a connection window")
    func inspectorIsNotAConnectionWindow() {
        #expect(ConnectionWindowIdentity.isConnectionWindow("main"))
        #expect(!ConnectionWindowIdentity.isConnectionWindow("main-inspector"))
        #expect(!ConnectionWindowIdentity.isConnectionWindow(nil))
        #expect(!ConnectionWindowIdentity.isConnectionWindow("welcome"))
    }

    @Test("The document inspector still counts as a primary window")
    func inspectorIsAPrimaryWindow() {
        #expect(ConnectionWindowIdentity.isPrimaryWindow("main"))
        #expect(ConnectionWindowIdentity.isPrimaryWindow("main-inspector"))
        #expect(!ConnectionWindowIdentity.isPrimaryWindow("welcome"))
        #expect(!ConnectionWindowIdentity.isPrimaryWindow(nil))
    }

    @Test("The inspector predicate matches its own windows only")
    func inspectorPredicate() {
        #expect(ConnectionWindowIdentity.isDataFileWindow("main-data-file"))
        #expect(ConnectionWindowIdentity.isDataFileWindow("main-data-file-2"))
        #expect(!ConnectionWindowIdentity.isDataFileWindow("main"))
        #expect(!ConnectionWindowIdentity.isDataFileWindow(nil))
        #expect(ConnectionWindowIdentity.isPrimaryWindow(WindowIdentifier.dataFile))
    }

    @Test("Welcome windows are recognised with and without a suffix")
    func welcomePredicate() {
        #expect(ConnectionWindowIdentity.isWelcomeWindow("welcome"))
        #expect(ConnectionWindowIdentity.isWelcomeWindow("welcome-1"))
        #expect(!ConnectionWindowIdentity.isWelcomeWindow("main"))
        #expect(!ConnectionWindowIdentity.isWelcomeWindow(nil))
    }

    @Test("Welcome appears only when the last primary window goes away")
    func welcomeVisibilityPolicy() {
        #expect(
            WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: true, remainingVisiblePrimaryWindows: 0, sessionOrigin: .user
            )
        )
        #expect(
            !WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: true, remainingVisiblePrimaryWindows: 1, sessionOrigin: .user
            )
        )
        #expect(
            !WelcomeVisibilityPolicy.shouldPresentWelcome(
                closingWindowWasPrimary: false, remainingVisiblePrimaryWindows: 0, sessionOrigin: .user
            )
        )
    }
}
