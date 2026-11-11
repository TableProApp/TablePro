import AppKit
@testable import TablePro
import TableProEditorKit
import Testing

@MainActor
struct TriggerEditorFontSizeTests {
    @Test("New and Edit Trigger open at the size the DDL pane is zoomed to")
    func opensAtTheStoredSize() throws {
        let zoomed = try EphemeralDefaults()
        zoomed.defaults.set(18.0, forKey: TriggerEditorView.fontSizeKey)

        #expect(TriggerEditorView.initialConfiguration(in: zoomed.defaults).appearance.font.pointSize == 18)
    }

    @Test("Without a stored size the sheet opens at the default")
    func opensAtTheDefaultSize() throws {
        let fresh = try EphemeralDefaults()

        #expect(
            TriggerEditorView.initialConfiguration(in: fresh.defaults).appearance.font.pointSize
                == CGFloat(TriggerEditorView.defaultFontSize)
        )
    }
}
