import Testing

@testable import TableProModels

@Suite("SafeModeLevel write permission")
struct SafeModeLevelTests {
    @Test("off proceeds without confirmation")
    func offProceeds() {
        #expect(SafeModeLevel.off.writePermission == .proceed)
    }

    @Test("confirmWrites requires confirmation")
    func confirmWritesRequiresConfirmation() {
        #expect(SafeModeLevel.confirmWrites.writePermission == .requiresConfirmation)
    }

    @Test("readOnly blocks writes")
    func readOnlyBlocks() {
        #expect(SafeModeLevel.readOnly.writePermission == .blocked)
    }
}
