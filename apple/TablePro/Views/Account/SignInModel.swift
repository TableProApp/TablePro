//
//  SignInModel.swift
//  TablePro
//

import Combine
import Foundation

// The "Sign in to TablePro" window (clients.md, First launch). Sign-in registers this Mac, refreshes the token so it
// names the device, then fetches the entitlement, all in AccountServices.signIn.
@MainActor
internal final class SignInModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case signingIn
        case failed(String)
        case signedIn(email: String?, plan: String?)
        case deviceLimit
    }

    @Published private(set) var phase: Phase = .ready
    @Published var presentsDeviceLimit = false

    let services: AccountServices

    init(services: AccountServices) {
        self.services = services
    }

    var isSigningIn: Bool {
        phase == .signingIn
    }

    func signIn(using authenticator: some WebAuthenticating) async {
        guard phase != .signingIn else { return }
        phase = .signingIn
        do throws(AccountError) {
            try await services.signIn(using: authenticator)
        } catch {
            // Closing the sheet or declining on the confirmation screen leaves the window as it was.
            phase = error.friendlyDescription.map(Phase.failed) ?? .ready
            return
        }
        settle(presentsSheet: true)
    }

    // After sign-in, and again once the device limit sheet closes, whether or not a device was removed there.
    func settle(presentsSheet: Bool) {
        let state = services.access.state
        if case .deviceLimitReached = state.refresh {
            phase = .deviceLimit
            presentsDeviceLimit = presentsSheet
            return
        }
        let entitlement = state.entitlement
        phase = .signedIn(email: entitlement?.email, plan: entitlement.map(Self.planSummary))
    }

    static func planSummary(_ entitlement: Entitlement) -> String {
        guard let license = entitlement.licenses.first else {
            return String(localized: "Free")
        }
        let plan = AccountCodes.planName(license.plan)
        guard let cycle = AccountCodes.cycleName(license.cycle) else { return plan }
        return String(format: String(localized: "%@, %@"), plan, cycle)
    }
}
