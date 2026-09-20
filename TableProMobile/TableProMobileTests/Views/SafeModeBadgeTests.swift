@testable import TableProMobile
import TableProModels
import Testing

@Suite("Safe mode badge")
struct SafeModeBadgeTests {
    @Test("Safe Mode off shows no badge")
    func offHasNoBadge() {
        #expect(SafeModeBadge(level: .off) == nil)
    }

    @Test("Read-only reads as blocked")
    func readOnlyIsBlocked() throws {
        let badge = try #require(SafeModeBadge(level: .readOnly))

        #expect(badge.tint == .blocked)
        #expect(badge.symbolName == "lock.fill")
        #expect(!badge.title.isEmpty)
    }

    @Test("Confirm writes reads as cautioned")
    func confirmWritesIsCautioned() throws {
        let badge = try #require(SafeModeBadge(level: .confirmWrites))

        #expect(badge.tint == .cautioned)
        #expect(badge.symbolName == "shield.fill")
        #expect(!badge.title.isEmpty)
    }

    @Test("Every level that blocks or questions a write carries a symbol and a title")
    func everyActiveLevelIsPresentableVertically() {
        for level in SafeModeLevel.allCases where level != .off {
            let badge = SafeModeBadge(level: level)
            #expect(badge != nil)
            #expect(badge?.symbolName.isEmpty == false)
            #expect(badge?.title.isEmpty == false)
        }
    }

    @Test("The two active levels are told apart")
    func activeLevelsAreDistinct() throws {
        let readOnly = try #require(SafeModeBadge(level: .readOnly))
        let confirmWrites = try #require(SafeModeBadge(level: .confirmWrites))

        #expect(readOnly != confirmWrites)
        #expect(readOnly.symbolName != confirmWrites.symbolName)
    }
}
