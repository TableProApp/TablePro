import AppKit
import SwiftUI
@testable import TablePro
import TableProTheme
import Testing

@MainActor
struct ThemeSlotRowTests {
    private typealias Fixture = ThemeLibraryTestFixture

    private static let gridBase = ThemeColor(red: 0x28, green: 0x2A, blue: 0x36)

    private static let dark = ThemeDefinition(
        id: "user.aaaa0002",
        name: "Midnight",
        author: "",
        appearance: .dark,
        overrides: [
            .editorBackground: Fixture.midnightBackground,
            .editorText: Fixture.pink,
            .syntaxKeyword: Fixture.green,
            .gridBackground: gridBase,
        ]
    )

    @Test("Every well and every reset is named apart for VoiceOver")
    func accessibilityLabelsAreUnique() {
        let slots = ThemeSlot.allCases
        let wells = Set(slots.map(\.accessibilityLabel))
        let resets = Set(slots.map { ThemeSlotPresentation(slot: $0, theme: Self.dark).resetAccessibilityLabel })

        #expect(wells.count == slots.count)
        #expect(resets.count == slots.count)
        #expect(
            ThemeSlotPresentation(slot: .editorBackground, theme: Self.dark).resetAccessibilityLabel
                == "Use System Color for Editor Background"
        )
    }

    @Test("The state line says where the color comes from")
    func stateLines() {
        func line(_ slot: ThemeSlot) -> String {
            ThemeSlotPresentation(slot: slot, theme: Self.dark).stateLine
        }
        #expect(line(.editorBackground) == Fixture.midnightBackground.hex)
        #expect(line(.windowBackdrop) == "System color")
        #expect(line(.syntaxString) == "Default Dark color")
        #expect(line(.syntaxOperator) == "Based on Editor Text")
        #expect(line(.gridAlternateRow) == "Based on Data Grid Background")
        #expect(line(.gridBoolTrue) == "System color")
        for slot in [ThemeSlot.gridHeaderBackground, .gridHeaderText, .gridSelection, .gridSelectionText, .gridInactiveSelection, .gridFocusBorder] {
            #expect(line(slot) == "System color", "\(slot.rawValue)")
            #expect(ThemeSlotPresentation(slot: slot, theme: Self.dark).resetTitle == "Use System Color", "\(slot.rawValue)")
        }

        var light = Self.dark
        light.appearance = .light
        #expect(ThemeSlotPresentation(slot: .syntaxString, theme: light).stateLine == "Default Light color")
    }

    @Test("Reset names what it returns to, and shows only for a slot the file sets")
    func resetTitles() {
        func presentation(_ slot: ThemeSlot, _ theme: ThemeDefinition = ThemeSlotRowTests.dark) -> ThemeSlotPresentation {
            ThemeSlotPresentation(slot: slot, theme: theme)
        }
        #expect(presentation(.editorBackground).hasExplicitColor)
        #expect(presentation(.editorBackground).resetTitle == "Use System Color")
        #expect(presentation(.syntaxKeyword).resetTitle == "Use Default Color")
        #expect(!presentation(.windowBackdrop).hasExplicitColor)

        var striped = Self.dark
        striped.overrides[.gridAlternateRow] = Fixture.pink
        #expect(presentation(.gridAlternateRow, striped).resetTitle == "Use Default Color")
        striped.overrides[.gridBackground] = nil
        #expect(presentation(.gridAlternateRow, striped).resetTitle == "Use System Color")
    }

    @Test("An unset slot's well shows the system color in the theme's appearance")
    func unsetSlotShowsTheSystemColorOfTheThemeAppearance() throws {
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        var expected = ThemeColor(red: 0, green: 0, blue: 0)
        darkAqua.performAsCurrentDrawingAppearance {
            expected = ThemeColor(NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor)
        }

        #expect(ThemeSlotPresentation(slot: .windowBackdrop, theme: Self.dark).displayColor == expected)
        #expect(ThemeSlotPresentation(slot: .editorBackground, theme: Self.dark).displayColor == Fixture.midnightBackground)
        let keyword = DefaultSyntaxPalette.color(for: .syntaxString, appearance: .dark, highContrast: false)
        #expect(ThemeSlotPresentation(slot: .syntaxString, theme: Self.dark).displayColor == keyword)
    }

    @Test("The contrast note appears only below 4.5:1")
    func contrastNote() {
        var low = Self.dark
        low.overrides[.editorText] = ThemeColor(red: 0x55, green: 0x57, blue: 0x66)
        let message = ThemeContrastNote.message(for: .editor, in: low)
        #expect(message?.hasPrefix("Text contrast is ") == true)
        #expect(message?.hasSuffix(":1. Aim for at least 4.5:1.") == true)

        #expect(ThemeContrastNote.message(for: .editor, in: Self.dark) == nil)
        #expect(ThemeContrastNote.message(for: .syntax, in: low) == nil)
    }

    @Test("A slot's well offers opacity only when the slot does")
    func wellOpacityFollowsTheSlot() throws {
        guard #available(macOS 14, *) else { return }
        for slot in [ThemeSlot.editorBackground, .editorText, .editorSelection, .gridDeleted] {
            let well = try hostedWell(for: slot)
            #expect(well.supportsAlpha == slot.offersOpacity, "\(slot.rawValue)")
        }
    }

    // The panel sends both wells' colors, made opaque, when alpha turns off; taken as picks they froze a system color.
    @Test("Activating a well is not a pick, and a color chosen in the panel still is")
    func activationIsNotAPick() throws {
        guard #available(macOS 14, *) else { return }
        let picks = PickRecorder()
        var theme = Fixture.theme("user.aaaa0003", "Paper", appearance: .light)
        theme.overrides[.editorCurrentLine] = ThemeColor(red: 0x00, green: 0x7A, blue: 0xFF, alpha: 0x14)
        let rows = Form {
            ForEach([ThemeSlot.editorCurrentLine, .gridLine], id: \.self) { slot in
                ThemeSlotRow(
                    presentation: ThemeSlotPresentation(slot: slot, theme: theme),
                    isEditable: true,
                    onSet: { picks.record(slot, $0) },
                    onReset: {}
                )
            }
        }
        .formStyle(.grouped)
        let (window, host) = Self.hostedWindow(rows, height: 200)
        window.orderFront(nil)
        let wells = Self.colorWells(in: host)
        let translucent = try #require(wells.first { $0.supportsAlpha })
        let opaque = try #require(wells.first { !$0.supportsAlpha })
        let panel = NSColorPanel.shared
        defer {
            for well in wells { well.deactivate() }
            panel.orderOut(nil)
            window.orderOut(nil)
        }

        translucent.activate(true)
        panel.orderFront(nil)
        opaque.activate(true)
        #expect(!panel.showsAlpha)
        #expect(picks.slots.isEmpty)

        panel.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        #expect(picks.slots.last == .gridLine)
        #expect(picks.colors.last == ThemeColor(red: 0xFF, green: 0x00, blue: 0x00))
    }

    @Test("A well is named for VoiceOver and dims when the theme cannot be edited")
    func wellAccessibilityAndState() throws {
        let (_, editable) = Self.hostedWindow(Self.row(for: .gridLine, isEditable: true), height: 120)
        let well = try #require(Self.colorWells(in: editable).first)
        #expect(well.accessibilityLabel() == ThemeSlot.gridLine.accessibilityLabel)
        #expect(well.accessibilityIdentifier() == "theme-color-dataGrid.gridLine")
        #expect(well.isEnabled)

        let (_, readOnly) = Self.hostedWindow(Self.row(for: .gridLine, isEditable: false), height: 120)
        #expect(Self.colorWells(in: readOnly).first?.isEnabled == false)
    }

    private func hostedWell(for slot: ThemeSlot) throws -> NSColorWell {
        let (window, host) = Self.hostedWindow(Self.row(for: slot, isEditable: true), height: 120)
        defer { window.orderOut(nil) }
        guard let well = Self.colorWells(in: host).first else { throw CocoaError(.featureUnsupported) }
        return well
    }

    private static func row(for slot: ThemeSlot, isEditable: Bool) -> some View {
        Form {
            ThemeSlotRow(
                presentation: ThemeSlotPresentation(slot: slot, theme: Self.dark),
                isEditable: isEditable,
                onSet: { _ in },
                onReset: {}
            )
        }
        .formStyle(.grouped)
    }

    private static func hostedWindow<Content: View>(_ content: Content, height: CGFloat) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func colorWells(in root: NSView) -> [NSColorWell] {
        var found: [NSColorWell] = []
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let well = view as? NSColorWell { found.append(well) }
            pending.append(contentsOf: view.subviews)
        }
        return found
    }
}

@MainActor
private final class PickRecorder {
    private(set) var slots: [ThemeSlot] = []
    private(set) var colors: [ThemeColor] = []

    func record(_ slot: ThemeSlot, _ color: ThemeColor) {
        slots.append(slot)
        colors.append(color)
    }
}
