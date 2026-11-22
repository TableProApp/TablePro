@testable import TablePro
import Testing

struct SettingsChoicesTests {
    @Test("A stored value on the list adds no extra item")
    func onListValueAddsNothing() {
        let options = SettingsChoices.options([5, 10, 30, 60], including: 30)
        #expect(options.fixed == [5, 10, 30, 60])
        #expect(options.extra == nil)
    }

    @Test("An off-list value becomes the extra item and the fixed list stays as it was")
    func offListValueBecomesExtra() {
        let options = SettingsChoices.options([5, 10, 30, 60], including: 90)
        #expect(options.fixed == [5, 10, 30, 60])
        #expect(options.extra == 90)
    }

    @Test("A value is never listed twice")
    func neverDuplicates() {
        for current in [5, 10, 45] {
            let options = SettingsChoices.options([5, 10], including: current)
            let shown = options.fixed + [options.extra].compactMap { $0 }
            #expect(Set(shown).count == shown.count)
            #expect(shown.contains(current))
        }
    }

    @Test("A font family that is no longer installed is kept as the extra item")
    func stringValues() {
        let options = SettingsChoices.options(["Menlo", "SF Mono"], including: "Fira Code")
        #expect(options.fixed == ["Menlo", "SF Mono"])
        #expect(options.extra == "Fira Code")
    }

    @Test("An optional selection such as No limit works the same way")
    func optionalValues() {
        let fixed: [Int?] = [nil, 100, 1000]
        #expect(SettingsChoices.options(fixed, including: nil).extra == nil)
        #expect(SettingsChoices.options(fixed, including: 250).extra == .some(250))
    }
}
