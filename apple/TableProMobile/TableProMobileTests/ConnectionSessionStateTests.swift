import Foundation
import TableProDatabase
@testable import TableProMobile
import Testing

@MainActor
struct ConnectionSessionStateTests {
    private let failure = AppError(
        category: .network,
        title: "Connection Failed",
        message: "The server closed the connection.",
        recovery: nil,
        underlying: nil
    )

    private func session(on driver: MockDatabaseDriver) -> ConnectionSession {
        ConnectionSession(connectionId: UUID(), driver: driver, activeDatabase: "app")
    }

    private func isConnected(_ state: ConnectionSessionState?, on driver: MockDatabaseDriver) -> Bool {
        guard case .connected(let landed)? = state else { return false }
        return landed.driver === driver
    }

    private func isLost(_ state: ConnectionSessionState?) -> Bool {
        guard case .lost? = state else { return false }
        return true
    }

    private func isNotConnected(_ state: ConnectionSessionState?) -> Bool {
        guard case .notConnected? = state else { return false }
        return true
    }

    private func showsConnected(_ state: ConnectionSessionState?) -> Bool {
        guard case .connected? = state?.phase else { return false }
        return true
    }

    private func showsLost(_ state: ConnectionSessionState?) -> Bool {
        guard case .lost? = state?.phase else { return false }
        return true
    }

    @Test("An open lands only with a session, so a connected state always has one")
    func openLandsOnlyWithASession() {
        let open = ConnectionAttempt(.open)
        let driver = MockDatabaseDriver()
        let started = ConnectionSessionState.notConnected.applying(.open(open))

        #expect(started?.isOpening == true)
        #expect(started?.session == nil)
        #expect(started?.applying(.opened(open)) == nil)

        let loading = started?.applying(.adopt(session(on: driver), by: open))
        #expect(loading?.isOpening == true)
        #expect(loading?.session?.driver === driver)
        #expect(isConnected(loading?.applying(.opened(open)), on: driver))
    }

    @Test("A database restore that fails both ways inside an open ends it lost, and the open can no longer land")
    func failedRestoreEndsTheOpenLost() {
        let open = ConnectionAttempt(.open)
        let loading = ConnectionSessionState.connecting(open, provisional: session(on: MockDatabaseDriver()))

        let tornDown = loading.applying(.teardown(open))
        #expect(tornDown?.isOpening == true)
        #expect(tornDown?.session == nil)

        let lost = tornDown?.applying(.lose(failure, open))
        #expect(isLost(lost))
        #expect(lost?.applying(.opened(open)) == nil)
        #expect(lost?.applying(.adopt(session(on: MockDatabaseDriver()), by: open)) == nil)
    }

    @Test("A step of an attempt the state no longer holds is refused")
    func staleStepsAreRefused() {
        let driver = MockDatabaseDriver()
        let first = ConnectionAttempt(.open)
        let abandoned = ConnectionSessionState.connecting(first, provisional: nil).applying(.abandon(first))

        #expect(isNotConnected(abandoned))
        #expect(abandoned?.applying(.adopt(session(on: driver), by: first)) == nil)
        #expect(abandoned?.applying(.fail(failure, first)) == nil)
        #expect(ConnectionSessionState.connecting(first, provisional: nil).applying(.open(ConnectionAttempt(.open))) == nil)

        let check = ConnectionAttempt(.redial)
        let checking = ConnectionSessionState.connected(session(on: driver)).applying(.check(check))
        let reopened = checking?.applying(.open(ConnectionAttempt(.open)))
        #expect(reopened?.isOpening == true)
        #expect(reopened?.applying(.dial(check)) == nil)
        #expect(reopened?.applying(.lose(failure, check)) == nil)
        #expect(reopened?.applying(.adopt(session(on: driver), by: check)) == nil)
    }

    @Test("A check pings in place, and only its redial reads as reconnecting")
    func checkReconnectsOnlyOnceItDials() {
        let held = MockDatabaseDriver()
        let check = ConnectionAttempt(.redial)
        let checking = ConnectionSessionState.connected(session(on: held)).applying(.check(check))

        #expect(checking?.check === check)
        #expect(checking?.isReconnecting == false)
        #expect(checking?.session?.driver === held)
        #expect(showsConnected(checking))

        let dialing = checking?.applying(.dial(check))
        #expect(dialing?.isReconnecting == true)
        #expect(dialing?.session?.driver === held)
        #expect(isLost(dialing?.applying(.lose(failure, check))))

        let redialed = MockDatabaseDriver()
        let retry = ConnectionAttempt(.redial)
        let lostChecking = ConnectionSessionState.lost(failure).applying(.check(retry))
        #expect(showsLost(lostChecking))
        #expect(lostChecking?.session == nil)
        let lostDialing = lostChecking?.applying(.dial(retry))
        #expect(lostDialing?.isReconnecting == true)
        #expect(isConnected(lostDialing?.applying(.adopt(session(on: redialed), by: retry)), on: redialed))
    }

    @Test("A check starts only over a connected or a lost session")
    func checkNeedsASessionOrALoss() {
        let driver = MockDatabaseDriver()
        let switching = ConnectionAttempt(.switchDatabase)
        let states: [ConnectionSessionState] = [
            .notConnected,
            .failed(failure),
            .connecting(ConnectionAttempt(.open), provisional: session(on: driver)),
            .reconnecting(switching, over: .connected(session(on: driver)))
        ]
        for state in states {
            #expect(state.applying(.check(ConnectionAttempt(.redial))) == nil)
        }
    }

    @Test("A session another window moved lands under a running check without ending it")
    func followLandsUnderACheck() {
        let check = ConnectionAttempt(.redial)
        let moved = MockDatabaseDriver()
        let checking = ConnectionSessionState.checking(check, over: .connected(session(on: MockDatabaseDriver())))

        let followed = checking.applying(.adopt(session(on: moved), by: nil))
        #expect(followed?.check === check)
        #expect(followed?.session?.driver === moved)
        #expect(isConnected(followed?.applying(.settle(check)), on: moved))
    }

    @Test("A PostgreSQL database switch shows no session until the new one lands, and is not a reconnect")
    func databaseSwitchHasNoSessionUntilItLands() {
        let switching = ConnectionAttempt(.switchDatabase)
        let staging = MockDatabaseDriver()
        let torn = ConnectionSessionState.connected(session(on: MockDatabaseDriver())).applying(.switchDatabase(switching))

        #expect(torn?.session == nil)
        #expect(torn?.isReconnecting == false)
        #expect(showsConnected(torn))
        #expect(torn?.applying(.adopt(session(on: staging), by: nil)) == nil)
        #expect(isConnected(torn?.applying(.adopt(session(on: staging), by: switching)), on: staging))
        #expect(isLost(torn?.applying(.lose(failure, switching))))
    }

    @Test("A database switch waits for a running check, and may start over a loss")
    func databaseSwitchWaitsForACheck() {
        let held = session(on: MockDatabaseDriver())
        let check = ConnectionAttempt(.redial)
        let checking = ConnectionSessionState.checking(check, over: .connected(held))
        let redialing = ConnectionSessionState.reconnecting(check, over: .connected(held))

        #expect(checking.applying(.switchDatabase(ConnectionAttempt(.switchDatabase))) == nil)
        #expect(redialing.applying(.switchDatabase(ConnectionAttempt(.switchDatabase))) == nil)

        let overLoss = ConnectionSessionState.lost(failure).applying(.switchDatabase(ConnectionAttempt(.switchDatabase)))
        #expect(overLoss?.session == nil)
        #expect(showsLost(overLoss))
        #expect(overLoss?.isReconnecting == false)
    }

    @Test("An open every window left goes back to the loss it started from, and a reset ends neutral")
    func abandonedOpenKeepsItsLoss() {
        let fromLoss = ConnectionAttempt(.open, origin: .lost(failure))
        let reopening = ConnectionSessionState.connecting(fromLoss, provisional: session(on: MockDatabaseDriver()))
        let fresh = ConnectionAttempt(.open)

        #expect(isLost(reopening.applying(.abandon(fromLoss))))
        #expect(isNotConnected(ConnectionSessionState.connecting(fresh, provisional: nil).applying(.abandon(fresh))))
        #expect(reopening.applying(.abandon(fresh)) == nil)
        #expect(isNotConnected(reopening.applying(.cancel)))
    }

    @Test("At rest, an open shows the loss it started from and a switch the session it started over")
    func restingStateSkipsWhatIsInFlight() {
        let held = MockDatabaseDriver()
        let reopening = ConnectionSessionState.connecting(ConnectionAttempt(.open, origin: .lost(failure)), provisional: nil)
        let switching = ConnectionSessionState.reconnecting(
            ConnectionAttempt(.switchDatabase), over: .connected(session(on: held))
        )

        #expect(isLost(reopening.atRest))
        #expect(isConnected(switching.atRest, on: held))
        #expect(isNotConnected(ConnectionSessionState.connecting(ConnectionAttempt(.open), provisional: nil).atRest))
    }
}
