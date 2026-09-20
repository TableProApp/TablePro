@testable import TableProMobile
import Testing

@Suite("Attempt waiters")
struct AttemptWaitersTests {
    @Test("The only screen waiting abandons the attempt when it leaves")
    func lastWaiterAbandonsTheAttempt() {
        var waiters = AttemptWaiters()
        waiters.join()

        #expect(waiters.leave() == true)
        #expect(waiters.isAwaited == false)
    }

    @Test("A screen replaced by another leaves the attempt running for it")
    func replacedScreenKeepsTheAttempt() {
        var waiters = AttemptWaiters()
        waiters.join()
        waiters.join()

        #expect(waiters.leave() == false, "the second screen is still waiting")
        #expect(waiters.isAwaited)
        #expect(waiters.leave() == true)
    }

    @Test("Leaving more often than joining never goes negative")
    func leavingTwiceIsHarmless() {
        var waiters = AttemptWaiters()
        waiters.join()

        #expect(waiters.leave() == true)
        #expect(waiters.leave() == true)
        #expect(waiters.isIdle)
    }
}
