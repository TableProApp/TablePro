import AppKit
import Combine
import SwiftUI
@testable import TablePro
import TableProTestSupport
import Testing

struct EditorFontResolverTests {
    @Test("The family list puts System Mono first, then unique names sorted, with no hidden system families")
    func familyOptionsOrder() {
        let options = EditorFontResolver.familyOptions(
            from: ["Menlo", ".AppleSystemUIFontMonospaced", "andale mono", "Menlo", "System Mono", "Courier New"]
        )
        #expect(options.map { $0.id } == ["System Mono", "andale mono", "Courier New", "Menlo"])
        #expect(options.allSatisfy { $0.id == $0.displayName })
    }

    @Test("No family installed still offers System Mono")
    func emptyFamilyList() {
        #expect(EditorFontResolver.familyOptions(from: []).map { $0.id } == [EditorFontResolver.systemMonoId])
    }

    @Test("The installed monospaced families start with System Mono and are sorted and unique")
    func installedFamilies() {
        let ids = EditorFontResolver.availableMonospacedFamilies().map { $0.id }
        #expect(ids.first == EditorFontResolver.systemMonoId)
        let rest = Array(ids.dropFirst())
        #expect(Set(ids).count == ids.count)
        #expect(!rest.contains { $0.hasPrefix(".") })
        #expect(zip(rest, rest.dropFirst()).allSatisfy { $0.localizedCaseInsensitiveCompare($1) != .orderedDescending })
    }

    @Test("A family that is not installed draws System Mono at the asked size")
    func missingFamilyResolvesToSystemMono() {
        let font = EditorFontResolver.resolve(familyId: "No Such Family 7d1c", size: 15)
        #expect(font.pointSize == 15)
        #expect(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }
}

@MainActor
struct MonospacedFontFamiliesTests {
    private final class InstalledFonts {
        var names: [String] = ["Menlo"]
    }

    private final class ChangeCount {
        var value = 0
    }

    @Test("Installing a font while the app runs rebuilds the list")
    func rebuildsOnFontSetChange() async throws {
        let center = NotificationCenter()
        let installed = InstalledFonts()
        let families = MonospacedFontFamilies(notificationCenter: center) {
            EditorFontResolver.familyOptions(from: installed.names)
        }
        #expect(families.families.map { $0.id } == ["System Mono", "Menlo"])

        installed.names = ["Menlo", "Fira Code"]
        center.post(name: NSFont.fontSetChangedNotification, object: nil)

        try await waitUntil { families.families.map { $0.id } == ["System Mono", "Fira Code", "Menlo"] }
    }

    @Test("A reload that finds the same families publishes nothing")
    func unchangedReloadIsSilent() {
        let installed = InstalledFonts()
        let families = MonospacedFontFamilies(notificationCenter: NotificationCenter()) {
            EditorFontResolver.familyOptions(from: installed.names)
        }
        let changes = ChangeCount()
        let subscription = families.objectWillChange.sink { _ in changes.value += 1 }
        families.reload()
        #expect(changes.value == 0)
        installed.names = ["Menlo", "PT Mono"]
        families.reload()
        #expect(changes.value == 1)
        subscription.cancel()
    }
}

@MainActor
struct TypographyRowsTests {
    private let families = EditorFontResolver.familyOptions(from: ["Menlo", "Monaco"])

    @Test("An installed family adds no extra item")
    func installedFamilyIsListed() {
        #expect(TypographyRows.missingFamily("Menlo", in: families) == nil)
        #expect(TypographyRows.missingFamily(EditorFontResolver.systemMonoId, in: families) == nil)
    }

    @Test("A saved family that is gone stays selectable under its own name")
    func missingFamilyIsKept() {
        #expect(TypographyRows.missingFamily("Fira Code", in: families) == "Fira Code")
        #expect(TypographyRows.notInstalledTitle("Fira Code").contains("Fira Code"))
    }

    @Test("The size pop-up shows the drawn size and a pick writes the stored field")
    func sizeBindingClamps() {
        let slice = SettingsSlice(TypographySettings(editorFontSize: 40, dataGridFontSize: 5))
        let editor = TypographyRows.sizeBinding(.editor, of: sliceBinding(slice))
        let grid = TypographyRows.sizeBinding(.dataGrid, of: sliceBinding(slice))
        #expect(editor.wrappedValue == TypographySettings.sizeRange.upperBound)
        #expect(grid.wrappedValue == TypographySettings.sizeRange.lowerBound)

        editor.wrappedValue = 16
        #expect(slice.value.editorFontSize == 16)
        #expect(slice.value.dataGridFontSize == 5)
    }

    @Test("Each domain reads and writes its own family")
    func familyBindingPerDomain() {
        let slice = SettingsSlice(TypographySettings(editorFontFamily: "Menlo", dataGridFontFamily: "Monaco"))
        let editor = TypographyRows.familyBinding(.editor, of: sliceBinding(slice))
        let grid = TypographyRows.familyBinding(.dataGrid, of: sliceBinding(slice))
        #expect(editor.wrappedValue == "Menlo")
        #expect(grid.wrappedValue == "Monaco")

        grid.wrappedValue = EditorFontResolver.systemMonoId
        #expect(slice.value.dataGridFontFamily == EditorFontResolver.systemMonoId)
        #expect(slice.value.editorFontFamily == "Menlo")
    }
}

@MainActor
struct EditorTabWidthChoiceTests {
    @Test("A tab width off the list is offered after the list")
    func offListTabWidth() {
        let options = SettingsChoices.options(EditorSettingsView.tabWidths, including: EditorSettings(tabWidth: 3).clampedTabWidth)
        #expect(options.fixed == [2, 4, 8])
        #expect(options.extra == 3)
    }

    @Test("The tab width pop-up shows the width the editor uses and a pick writes the stored field")
    func tabWidthBindingClamps() {
        let slice = SettingsSlice(EditorSettings(tabWidth: 40))
        let binding = EditorSettingsView.tabWidthBinding(sliceBinding(slice))
        #expect(binding.wrappedValue == 16)

        binding.wrappedValue = 2
        #expect(slice.value.tabWidth == 2)
    }
}

// The binding a pane gets from $slice.value.
@MainActor
private func sliceBinding<Value>(_ slice: SettingsSlice<Value>) -> Binding<Value> {
    ObservedObject(wrappedValue: slice).projectedValue.value
}
