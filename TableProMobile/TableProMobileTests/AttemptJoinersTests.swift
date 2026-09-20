@testable import TableProMobile
import Testing

@Suite("Attempt joiners")
struct AttemptJoinersTests {
    @Test("The only screen waiting abandons the attempt when it leaves")
    func lastJoinerAbandonsTheAttempt() {
        var joiners = AttemptJoiners()
        let screen = joiners.join()

        #expect(joiners.leave(screen) == true)
        #expect(joiners.isEmpty)
    }

    @Test("A screen replaced by another leaves the attempt running for it")
    func replacedScreenKeepsTheAttempt() {
        var joiners = AttemptJoiners()
        let first = joiners.join()
        let second = joiners.join()

        #expect(joiners.leave(first) == false, "the second screen is still waiting")
        #expect(!joiners.isEmpty)
        #expect(joiners.leave(second) == true)
    }

    @Test("A screen that leaves twice is counted once")
    func leavingTwiceCountsOnce() {
        var joiners = AttemptJoiners()
        let screen = joiners.join()
        let other = joiners.join()

        #expect(joiners.leave(screen) == false)
        #expect(joiners.leave(screen) == false, "the second leave must not speak for the other screen")
        #expect(!joiners.isEmpty)
        #expect(joiners.leave(other) == true)
    }
}
