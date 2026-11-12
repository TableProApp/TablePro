import Foundation
import TableProTheme
import Testing

struct ThemeSlotTests {
    @Test("Slot paths are unique and sit under their group's key")
    func slotPathsAreWellFormed() {
        let paths = ThemeSlot.allCases.map(\.rawValue)
        #expect(Set(paths).count == paths.count)

        for slot in ThemeSlot.allCases {
            switch slot.group {
            case .window:
                #expect(slot.rawValue.hasPrefix("window."), "\(slot.rawValue)")
            case .editor:
                #expect(slot.rawValue.hasPrefix("editor."), "\(slot.rawValue)")
                #expect(!slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .syntax:
                #expect(slot.rawValue.hasPrefix("editor.syntax."), "\(slot.rawValue)")
            case .dataGrid:
                #expect(slot.rawValue.hasPrefix("dataGrid."), "\(slot.rawValue)")
            }
        }
    }

    @Test("The registry holds 42 slots")
    func slotCount() {
        #expect(ThemeSlot.allCases.count == 42)
    }

    @Test("The value slots sit under the data grid key")
    func valueSlots() {
        let expected: [String: ThemeSlot] = [
            "dataGrid.string": .gridString,
            "dataGrid.number": .gridNumber,
            "dataGrid.dateTime": .gridDateTime,
            "dataGrid.binary": .gridBinary,
            "dataGrid.json": .gridJSON,
            "dataGrid.uuid": .gridUUID,
            "dataGrid.enum": .gridEnum,
        ]
        for (path, slot) in expected {
            #expect(ThemeSlot(rawValue: path) == slot, "\(path)")
            #expect(slot.group == .dataGrid, "\(path)")
            #expect(slot.introducedInSchema == 4, "\(path)")
        }
    }

    @Test("Every slot came with format 3 or a later one this build reads, and the newest is the current format")
    func slotsCarryTheirFormat() {
        let formats = ThemeSlot.allCases.map(\.introducedInSchema)
        #expect(formats.allSatisfy { (ThemeSchema.oldestReadable...ThemeSchema.current).contains($0) })
        #expect(formats.max() == ThemeSchema.current)
        let format3 = ThemeSlot.allCases.filter { $0.introducedInSchema == ThemeSchema.oldestReadable }
        #expect(format3.count == 35)
    }

    @Test("Every slot belongs to exactly one group, listed in registry order")
    func groupsPartitionTheSlots() {
        let grouped = ThemeSlotGroup.allCases.flatMap(\.slots)
        #expect(Set(grouped) == Set(ThemeSlot.allCases))
        #expect(grouped.count == ThemeSlot.allCases.count)
        let gridPaths = ThemeSlot.allCases.filter { $0.rawValue.hasPrefix("dataGrid.") }
        #expect(ThemeSlotGroup.dataGrid.slots == gridPaths)
    }

    @Test("Every slot belongs to exactly one section")
    func sectionsPartitionTheSlots() {
        let sectioned = ThemeSlotSection.allCases.flatMap(\.slots)
        #expect(Set(sectioned) == Set(ThemeSlot.allCases))
        #expect(sectioned.count == ThemeSlot.allCases.count)
    }

    @Test("The editor sections split the data grid into rows, values, selection and changes")
    func sectionsSplitTheGrid() {
        #expect(ThemeSlotSection.allCases == [.window, .editor, .syntax, .dataGrid, .values, .selection, .changes])
        #expect(ThemeSlotSection.window.slots == [.windowBackdrop])
        #expect(ThemeSlotSection.editor.slots == ThemeSlotGroup.editor.slots)
        #expect(ThemeSlotSection.syntax.slots == ThemeSlotGroup.syntax.slots)
        #expect(ThemeSlotSection.dataGrid.slots == [
            .gridBackground, .gridText, .gridAlternateRow, .gridHeaderBackground, .gridHeaderText, .gridLine, .gridRowNumber,
        ])
        #expect(ThemeSlotSection.values.slots == [
            .gridNullValue, .gridBoolTrue, .gridBoolFalse,
            .gridString, .gridNumber, .gridDateTime, .gridBinary, .gridJSON, .gridUUID, .gridEnum,
        ])
        #expect(ThemeSlotSection.values.label == "Values")
        #expect(ThemeSlotSection.selection.slots == [.gridSelection, .gridSelectionText, .gridInactiveSelection, .gridFocusBorder])
        #expect(ThemeSlotSection.changes.slots == [.gridModified, .gridInserted, .gridDeleted, .gridDeletedText])
    }

    @Test("The header and selection slots sit under the data grid key")
    func headerAndSelectionSlots() {
        let expected: [String: ThemeSlot] = [
            "dataGrid.headerBackground": .gridHeaderBackground,
            "dataGrid.headerText": .gridHeaderText,
            "dataGrid.selection": .gridSelection,
            "dataGrid.selectionText": .gridSelectionText,
            "dataGrid.inactiveSelection": .gridInactiveSelection,
            "dataGrid.focusBorder": .gridFocusBorder,
        ]
        for (path, slot) in expected {
            #expect(ThemeSlot(rawValue: path) == slot, "\(path)")
            #expect(slot.group == .dataGrid, "\(path)")
        }
    }

    @Test("The window group comes first and holds only the window background")
    func windowGroupLeads() {
        #expect(ThemeSlotGroup.allCases.first == .window)
        #expect(ThemeSlotGroup.window.slots == [.windowBackdrop])
        #expect(ThemeSlot.windowBackdrop.rawValue == "window.background")
        let yielding = ThemeSlot.allCases.filter { $0.yieldsToIncreasedContrast }
        #expect(yielding == [.windowBackdrop])
    }

    @Test("Every slot has a label and an accessibility label no other slot has")
    func accessibilityLabelsAreUnique() {
        let labels = ThemeSlot.allCases.map(\.accessibilityLabel)
        #expect(Set(labels).count == labels.count)
        for slot in ThemeSlot.allCases {
            #expect(!slot.label.isEmpty, "\(slot.rawValue)")
            #expect(slot.accessibilityLabel.contains(slot.label), "\(slot.rawValue)")
        }
        #expect(ThemeSlot.editorBackground.accessibilityLabel == "Editor Background")
        #expect(ThemeSlot.gridAlternateRow.accessibilityLabel == "Data Grid Alternate Row")
        #expect(ThemeSlot.gridSelection.accessibilityLabel == "Data Grid Selection")
        #expect(ThemeSlot.gridSelectionText.accessibilityLabel == "Data Grid Selected Text")
        #expect(ThemeSlot.windowBackdrop.accessibilityLabel == "Window Background")
        #expect(ThemeSlot.gridString.label == "String")
        #expect(ThemeSlot.gridString.accessibilityLabel == "Data Grid String")
        #expect(ThemeSlot.gridDateTime.label == "Date & Time")
        #expect(ThemeSlot.gridDateTime.accessibilityLabel == "Data Grid Date & Time")
        #expect(ThemeSlot.gridEnum.accessibilityLabel == "Data Grid Enum")
    }

    @Test("Only the fills under everything else require an opaque color")
    func opaqueSlots() {
        let opaque = Set(ThemeSlot.allCases.filter { $0.requiresOpaque })
        #expect(opaque == [.windowBackdrop, .editorBackground, .gridBackground, .gridHeaderBackground])
    }

    @Test("Opacity is offered on the washes and never on a slot that must be opaque")
    func opacityOffers() {
        let translucent = Set(ThemeSlot.allCases.filter { $0.offersOpacity })
        #expect(translucent == [
            .editorSelection, .editorCurrentLine, .editorCurrentStatement, .editorInvisibles,
            .gridAlternateRow, .gridSelection, .gridInactiveSelection,
            .gridModified, .gridInserted, .gridDeleted, .gridDeletedText,
        ])
        for slot in ThemeSlot.allCases {
            #expect(!(slot.offersOpacity && slot.requiresOpaque), "\(slot.rawValue)")
        }
    }
}
