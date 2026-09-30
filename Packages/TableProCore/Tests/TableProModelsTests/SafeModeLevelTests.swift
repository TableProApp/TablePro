import Testing

@testable import TableProModels

@Suite("SafeModeLevel")
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

    @Test("An iOS wire value decodes to its own level", arguments: SafeModeLevel.allCases)
    func decodesOwnWireValues(_ level: SafeModeLevel) {
        #expect(SafeModeLevel(wireValue: level.rawValue, isReadOnly: false) == level)
    }

    @Test(
        "A macOS confirmation level decodes to confirmWrites",
        arguments: ["alert", "alertFull", "safeMode", "safeModeFull"]
    )
    func decodesMacOSConfirmationLevels(_ wireValue: String) {
        #expect(SafeModeLevel(wireValue: wireValue, isReadOnly: false) == .confirmWrites)
    }

    @Test("macOS silent decodes to off")
    func decodesMacOSSilent() {
        #expect(SafeModeLevel(wireValue: "silent", isReadOnly: false) == .off)
    }

    @Test("An unrecognized wire value requires confirmation instead of failing open")
    func unknownWireValueFailsClosed() {
        #expect(SafeModeLevel(wireValue: "someFutureLevel", isReadOnly: false) == .confirmWrites)
        #expect(SafeModeLevel(wireValue: "someFutureLevel", isReadOnly: true) == .readOnly)
    }

    @Test("A missing wire value honors the read-only flag")
    func missingWireValueHonorsReadOnly() {
        #expect(SafeModeLevel(wireValue: nil, isReadOnly: true) == .readOnly)
        #expect(SafeModeLevel(wireValue: nil, isReadOnly: false) == .off)
    }
}
