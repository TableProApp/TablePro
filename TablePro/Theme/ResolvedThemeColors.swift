import AppKit
import SwiftUI

struct ResolvedEditorColors {
    let background: NSColor
    let backgroundSwiftUI: Color
    let text: NSColor
    let textSwiftUI: Color
    let cursor: NSColor
    let cursorSwiftUI: Color
    let currentLineHighlight: NSColor
    let currentLineHighlightSwiftUI: Color
    let selection: NSColor
    let selectionSwiftUI: Color
    let lineNumber: NSColor
    let lineNumberSwiftUI: Color
    let invisibles: NSColor
    let invisiblesSwiftUI: Color

    let keyword: NSColor
    let keywordSwiftUI: Color
    let string: NSColor
    let stringSwiftUI: Color
    let number: NSColor
    let numberSwiftUI: Color
    let comment: NSColor
    let commentSwiftUI: Color
    let null: NSColor
    let nullSwiftUI: Color
    let `operator`: NSColor
    let operatorSwiftUI: Color
    let function: NSColor
    let functionSwiftUI: Color
    let type: NSColor
    let typeSwiftUI: Color

    init(from colors: EditorThemeColors) {
        background = colors.background.nsColor
        backgroundSwiftUI = colors.background.swiftUIColor
        text = colors.text.nsColor
        textSwiftUI = colors.text.swiftUIColor
        cursor = colors.cursor.nsColor
        cursorSwiftUI = colors.cursor.swiftUIColor
        currentLineHighlight = colors.currentLineHighlight.nsColor
        currentLineHighlightSwiftUI = colors.currentLineHighlight.swiftUIColor
        selection = colors.selection.nsColor
        selectionSwiftUI = colors.selection.swiftUIColor
        lineNumber = colors.lineNumber.nsColor
        lineNumberSwiftUI = colors.lineNumber.swiftUIColor
        invisibles = colors.invisibles.nsColor
        invisiblesSwiftUI = colors.invisibles.swiftUIColor

        keyword = colors.syntax.keyword.nsColor
        keywordSwiftUI = colors.syntax.keyword.swiftUIColor
        string = colors.syntax.string.nsColor
        stringSwiftUI = colors.syntax.string.swiftUIColor
        number = colors.syntax.number.nsColor
        numberSwiftUI = colors.syntax.number.swiftUIColor
        comment = colors.syntax.comment.nsColor
        commentSwiftUI = colors.syntax.comment.swiftUIColor
        null = colors.syntax.null.nsColor
        nullSwiftUI = colors.syntax.null.swiftUIColor
        `operator` = colors.syntax.operator.nsColor
        operatorSwiftUI = colors.syntax.operator.swiftUIColor
        function = colors.syntax.function.nsColor
        functionSwiftUI = colors.syntax.function.swiftUIColor
        type = colors.syntax.type.nsColor
        typeSwiftUI = colors.syntax.type.swiftUIColor
    }
}

struct ResolvedDataGridColors {
    let background: NSColor
    let backgroundSwiftUI: Color
    let text: NSColor
    let textSwiftUI: Color
    let alternateRow: NSColor
    let alternateRowSwiftUI: Color
    let nullValue: NSColor
    let nullValueSwiftUI: Color
    let boolTrue: NSColor
    let boolTrueSwiftUI: Color
    let boolFalse: NSColor
    let boolFalseSwiftUI: Color
    let rowNumber: NSColor
    let rowNumberSwiftUI: Color

    let modified: NSColor
    let modifiedSwiftUI: Color
    let modifiedCG: CGColor
    let inserted: NSColor
    let insertedSwiftUI: Color
    let insertedCG: CGColor
    let deleted: NSColor
    let deletedSwiftUI: Color
    let deletedCG: CGColor
    let deletedText: NSColor
    let deletedTextSwiftUI: Color

    let focusBorder: NSColor
    let focusBorderCG: CGColor

    init(from colors: DataGridThemeColors) {
        background = colors.background.nsColor
        backgroundSwiftUI = colors.background.swiftUIColor
        text = colors.text.nsColor
        textSwiftUI = colors.text.swiftUIColor
        alternateRow = colors.alternateRow.nsColor
        alternateRowSwiftUI = colors.alternateRow.swiftUIColor
        nullValue = colors.nullValue.nsColor
        nullValueSwiftUI = colors.nullValue.swiftUIColor
        boolTrue = colors.boolTrue.nsColor
        boolTrueSwiftUI = colors.boolTrue.swiftUIColor
        boolFalse = colors.boolFalse.nsColor
        boolFalseSwiftUI = colors.boolFalse.swiftUIColor
        rowNumber = colors.rowNumber.nsColor
        rowNumberSwiftUI = colors.rowNumber.swiftUIColor

        modified = colors.modified.nsColor
        modifiedSwiftUI = colors.modified.swiftUIColor
        modifiedCG = colors.modified.cgColor
        inserted = colors.inserted.nsColor
        insertedSwiftUI = colors.inserted.swiftUIColor
        insertedCG = colors.inserted.cgColor
        deleted = colors.deleted.nsColor
        deletedSwiftUI = colors.deleted.swiftUIColor
        deletedCG = colors.deleted.cgColor
        deletedText = colors.deletedText.nsColor
        deletedTextSwiftUI = colors.deletedText.swiftUIColor

        focusBorder = colors.focusBorder.nsColor
        focusBorderCG = colors.focusBorder.cgColor
    }
}

struct ResolvedUIColors {
    let windowBackground: NSColor
    let windowBackgroundSwiftUI: Color
    let controlBackground: NSColor
    let controlBackgroundSwiftUI: Color
    let cardBackground: NSColor
    let cardBackgroundSwiftUI: Color
    let border: NSColor
    let borderSwiftUI: Color

    let primaryText: NSColor
    let primaryTextSwiftUI: Color
    let secondaryText: NSColor
    let secondaryTextSwiftUI: Color
    let tertiaryText: NSColor
    let tertiaryTextSwiftUI: Color

    let accentColor: NSColor?
    let accentColorSwiftUI: Color?

    let selectionBackground: NSColor
    let selectionBackgroundSwiftUI: Color
    let hoverBackground: NSColor
    let hoverBackgroundSwiftUI: Color

    let success: NSColor
    let successSwiftUI: Color
    let warning: NSColor
    let warningSwiftUI: Color
    let error: NSColor
    let errorSwiftUI: Color
    let info: NSColor
    let infoSwiftUI: Color

    let badgeBackground: NSColor
    let badgeBackgroundSwiftUI: Color
    let badgePrimaryKey: NSColor
    let badgePrimaryKeySwiftUI: Color
    let badgeAutoIncrement: NSColor
    let badgeAutoIncrementSwiftUI: Color

    init(from colors: UIThemeColors) {
        windowBackground = colors.windowBackground.nsColor
        windowBackgroundSwiftUI = colors.windowBackground.swiftUIColor
        controlBackground = colors.controlBackground.nsColor
        controlBackgroundSwiftUI = colors.controlBackground.swiftUIColor
        cardBackground = colors.cardBackground.nsColor
        cardBackgroundSwiftUI = colors.cardBackground.swiftUIColor
        border = colors.border.nsColor
        borderSwiftUI = colors.border.swiftUIColor

        primaryText = colors.primaryText.nsColor
        primaryTextSwiftUI = colors.primaryText.swiftUIColor
        secondaryText = colors.secondaryText.nsColor
        secondaryTextSwiftUI = colors.secondaryText.swiftUIColor
        tertiaryText = colors.tertiaryText.nsColor
        tertiaryTextSwiftUI = colors.tertiaryText.swiftUIColor

        if let accent = colors.accentColor {
            accentColor = accent.nsColor
            accentColorSwiftUI = accent.swiftUIColor
        } else {
            accentColor = nil
            accentColorSwiftUI = nil
        }

        selectionBackground = colors.selectionBackground.nsColor
        selectionBackgroundSwiftUI = colors.selectionBackground.swiftUIColor
        hoverBackground = colors.hoverBackground.nsColor
        hoverBackgroundSwiftUI = colors.hoverBackground.swiftUIColor

        success = colors.status.success.nsColor
        successSwiftUI = colors.status.success.swiftUIColor
        warning = colors.status.warning.nsColor
        warningSwiftUI = colors.status.warning.swiftUIColor
        error = colors.status.error.nsColor
        errorSwiftUI = colors.status.error.swiftUIColor
        info = colors.status.info.nsColor
        infoSwiftUI = colors.status.info.swiftUIColor

        badgeBackground = colors.badges.background.nsColor
        badgeBackgroundSwiftUI = colors.badges.background.swiftUIColor
        badgePrimaryKey = colors.badges.primaryKey.nsColor
        badgePrimaryKeySwiftUI = colors.badges.primaryKey.swiftUIColor
        badgeAutoIncrement = colors.badges.autoIncrement.nsColor
        badgeAutoIncrementSwiftUI = colors.badges.autoIncrement.swiftUIColor
    }
}

struct ResolvedSidebarColors {
    let background: NSColor
    let backgroundSwiftUI: Color
    let text: NSColor
    let textSwiftUI: Color
    let selectedItem: NSColor
    let selectedItemSwiftUI: Color
    let hover: NSColor
    let hoverSwiftUI: Color
    let sectionHeader: NSColor
    let sectionHeaderSwiftUI: Color

    init(from colors: SidebarThemeColors) {
        background = colors.background.nsColor
        backgroundSwiftUI = colors.background.swiftUIColor
        text = colors.text.nsColor
        textSwiftUI = colors.text.swiftUIColor
        selectedItem = colors.selectedItem.nsColor
        selectedItemSwiftUI = colors.selectedItem.swiftUIColor
        hover = colors.hover.nsColor
        hoverSwiftUI = colors.hover.swiftUIColor
        sectionHeader = colors.sectionHeader.nsColor
        sectionHeaderSwiftUI = colors.sectionHeader.swiftUIColor
    }
}

struct ResolvedToolbarColors {
    let secondaryText: NSColor
    let secondaryTextSwiftUI: Color
    let tertiaryText: NSColor
    let tertiaryTextSwiftUI: Color

    init(from colors: ToolbarThemeColors) {
        secondaryText = colors.secondaryText.nsColor
        secondaryTextSwiftUI = colors.secondaryText.swiftUIColor
        tertiaryText = colors.tertiaryText.nsColor
        tertiaryTextSwiftUI = colors.tertiaryText.swiftUIColor
    }
}

struct ResolvedThemeColors {
    let editor: ResolvedEditorColors
    let dataGrid: ResolvedDataGridColors
    let ui: ResolvedUIColors
    let sidebar: ResolvedSidebarColors
    let toolbar: ResolvedToolbarColors

    init(from theme: ThemeDefinition) {
        editor = ResolvedEditorColors(from: theme.editor)
        dataGrid = ResolvedDataGridColors(from: theme.dataGrid)
        ui = ResolvedUIColors(from: theme.ui)
        sidebar = ResolvedSidebarColors(from: theme.sidebar)
        toolbar = ResolvedToolbarColors(from: theme.toolbar)
    }
}
