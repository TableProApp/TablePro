import Combine
import Foundation
import TableProFFI
import TableProHTTP
import UIKit

extension AppState {
    // The key calls go to the service the app holds now, so one opened again after a sign-in change is the one used.
    var keyFlows: @MainActor () async throws -> any AccountKeyFlows {
        let host = syncCoordinator.host
        return { try await host.keyService() }
    }

    // `anchor` is the window the step-up's sign-in sheet opens over.
    func keysEnvironment(anchor: @escaping () -> UIWindow?) -> AccountKeysEnvironment {
        let host = syncCoordinator.host
        let account = account
        return AccountKeysEnvironment(
            flows: keyFlows,
            keyChanges: host.keyChanges.eraseToAnyPublisher(),
            accountChanges: host.signInChanges.eraseToAnyPublisher(),
            stepUp: .live(account: account, anchor: anchor),
            resets: ResetKeysLiveService { try await host.keyService() },
            teamPage: { team in
                account.server.accountOrigin.appendingPathComponent("teams").appendingPathComponent(team)
            },
            // The portal's address comes from the server, so only an https page opens.
            openURL: { url in _ = WebPageOpener.open(url, scope: .https) },
            copySecret: { ClipboardExporter.copyToClipboard($0) },
            clock: ContinuousClock(),
            now: { Date() }
        )
    }

    func keysSignOut(askAfterFailure: @escaping @MainActor (String) async -> AccountKeysSignOutAnswer) -> AccountKeysSignOut {
        AccountKeysSignOut.over(keyFlows, askAfterFailure: askAfterFailure)
    }
}
