//
//  SignInModel.swift
//  TablePro
//

import Combine
import Foundation

// The "Sign in to TablePro" window (clients.md, First launch), for tablepro.app or a company server. The core signs in,
// registers this Mac and fetches the entitlement; this keeps what the window shows.
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
    @Published var entersCompanyServer: Bool
    @Published var companyServerAddress = ""
    @Published private(set) var server: AccountServer

    let services: AccountServices
    private var serverObserver: AnyCancellable?

    init(services: AccountServices, entersCompanyServer: Bool = false) {
        self.services = services
        let server = services.server
        self.server = server
        self.entersCompanyServer = entersCompanyServer && Self.offersOtherServers(server)
        serverObserver = services.access.$state
            .map(\.server)
            .removeDuplicates()
            .sink { [weak self] server in self?.server = server }
    }

    var isSigningIn: Bool {
        phase == .signingIn
    }

    // A configuration profile that bars other servers leaves nothing to choose; one that only names a server makes it
    // the default the person may leave.
    var offersOtherServers: Bool {
        Self.offersOtherServers(server)
    }

    var companyServerURL: URL? {
        CompanyServerAddress.parse(companyServerAddress)
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

    // Continue on Use a Company Server: discovery and the license check run first, then the browser sign-in.
    func signInToCompanyServer(using authenticator: some WebAuthenticating) async {
        guard phase != .signingIn else { return }
        guard let url = companyServerURL else {
            phase = .failed(AccountError.CompanyServerProblem.invalidAddress.description)
            return
        }
        phase = .signingIn
        do throws(AccountError) {
            try await services.chooseServer(url)
        } catch {
            phase = error.friendlyDescription.map(Phase.failed) ?? .ready
            return
        }
        entersCompanyServer = false
        phase = .ready
        await signIn(using: authenticator)
    }

    func useTableProServer() async {
        guard phase != .signingIn else { return }
        phase = .signingIn
        do throws(AccountError) {
            try await services.chooseServer(nil)
        } catch {
            phase = error.friendlyDescription.map(Phase.failed) ?? .ready
            return
        }
        phase = .ready
    }

    func showCompanyServer() {
        guard offersOtherServers else { return }
        if phase != .signingIn {
            phase = .ready
        }
        entersCompanyServer = true
    }

    func cancelCompanyServer() {
        if phase != .signingIn {
            phase = .ready
        }
        entersCompanyServer = false
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
        phase = .signedIn(
            email: entitlement?.email,
            plan: state.server.isProduction ? entitlement.map(Self.planSummary) : nil
        )
    }

    static func planSummary(_ entitlement: Entitlement) -> String {
        guard let license = entitlement.licenses.first else {
            return String(localized: "Free")
        }
        let plan = AccountCodes.planName(license.plan)
        guard let cycle = AccountCodes.cycleName(license.cycle) else { return plan }
        return String(format: String(localized: "%@, %@"), plan, cycle)
    }

    private static func offersOtherServers(_ server: AccountServer) -> Bool {
        server.othersAllowed
    }
}
