import SwiftUI

struct DataGridSection: View {
    static let pageSizes = [100, 500, 1_000, 5_000, 10_000]
    static let exactCountThresholds = [1_000, 10_000, 100_000, 1_000_000, Int.max]
    static let queryResultLimits = [100, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000]
    static let resultSetsKept = [0, 10, 20, 50, 100, 200, 500, 1_000]

    @Binding var settings: DataGridSettings
    let typography: SettingsSlice<TypographySettings>
    let valueColors: SettingsSlice<ValueColorSettings>
    let editor: SettingsSlice<EditorSettings>

    var body: some View {
        Section {
            DataFontRows(typography: typography)

            Picker("Row height", selection: $settings.rowHeight) {
                ForEach(DataGridRowHeight.allCases) { height in
                    Text(height.displayName).tag(height)
                }
            }
            .accessibilityIdentifier("data-row-height-picker")

            Toggle("Show alternate row backgrounds", isOn: $settings.showAlternateRows)
                .accessibilityIdentifier("data-alternate-rows-toggle")

            Toggle("Show row numbers", isOn: $settings.showRowNumbers)
                .accessibilityIdentifier("data-row-numbers-toggle")

            Toggle(isOn: $settings.wrapText) {
                Text("Wrap text in cells")
                Text("Long values wrap onto up to 10 lines in new tabs. View > Wrap Text changes the open grid.")
            }
            .accessibilityIdentifier("data-wrap-text-toggle")

            Toggle(isOn: $settings.showInvisibleCharacters) {
                Text("Show invisible characters")
                Text("Marks zero-width, control and special space characters in cells and value fields.")
            }
            .accessibilityIdentifier("data-invisible-characters-toggle")

            Toggle("Show inspector when a row is selected", isOn: $settings.autoShowInspector)
                .accessibilityIdentifier("data-auto-inspector-toggle")
        } header: {
            Text("Grid")
        }

        Section {
            Picker("Date format", selection: $settings.dateFormat) {
                ForEach(DateFormatOption.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .accessibilityIdentifier("data-date-format-picker")

            SettingsTextField(
                "NULL display",
                subtitle: "Up to \(SettingsValidationRules.nullDisplayMaxLength) characters",
                text: $settings.nullDisplay,
                prompt: Text(verbatim: "NULL"),
                validate: DataGridSettings.nullDisplayValidationError(for:),
                normalize: DataGridSettings.normalizedNullDisplay(_:)
            )
            .accessibilityIdentifier("data-null-display-field")

            ColorValuesByTypeToggle(valueColors: valueColors)

            Toggle(isOn: $settings.enableSmartValueDetection) {
                Text("Smart value detection")
                Text("Shows UUIDs, Unix timestamps, JSON and serialized values in a readable form, judged from the first rows.")
            }
            .accessibilityIdentifier("data-smart-detection-toggle")

            JSONViewModePicker(editor: editor)
        } header: {
            Text("Values")
        }

        Section {
            Picker(selection: $settings.defaultSortBehavior) {
                ForEach(DefaultSortBehavior.allCases) { behavior in
                    Text(behavior.displayName).tag(behavior)
                }
            } label: {
                Text("Default sort")
                Text("Applied when a table first opens.")
            }
            .accessibilityIdentifier("data-default-sort-picker")

            Picker(selection: $settings.defaultSortDirection) {
                ForEach(SortDirection.allCases) { direction in
                    Text(direction.displayName).tag(direction)
                }
            } label: {
                Text("Sort direction")
                Text("Also the direction of the first click on a column header.")
            }
            .accessibilityIdentifier("data-sort-direction-picker")
        } header: {
            Text("Sorting")
        }

        Section {
            Picker(selection: $settings.rowCopyFormat) {
                ForEach(RowCopyFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            } label: {
                Text("Copy rows as")
                Text("A single cell still copies its value. Edit > Copy Special offers every format.")
            }
            .accessibilityIdentifier("data-copy-format-picker")
        } header: {
            Text("Copying")
        }

        Section {
            Picker("Page size", selection: $settings.defaultPageSize) {
                SettingsChoiceItems(Self.pageSizes, including: settings.defaultPageSize) { size in
                    Text(Self.rowsTitle(size))
                }
            }
            .accessibilityIdentifier("data-page-size-picker")

            Picker(selection: $settings.countRowsIfEstimateLessThan) {
                SettingsChoiceItems(Self.exactCountThresholds, including: settings.countRowsIfEstimateLessThan) { threshold in
                    Text(Self.exactCountTitle(threshold))
                }
            } label: {
                Text("Exact row count")
                Text("Larger tables show an estimated count, which avoids a slow COUNT(*).")
            }
            .accessibilityIdentifier("data-exact-count-picker")

            Picker(selection: Self.queryResultLimitBinding($settings)) {
                Text("No limit").tag(Int?.none)
                Divider()
                SettingsChoiceItems(
                    Self.queryResultLimits.map { Optional($0) },
                    including: settings.queryResultLimit ?? Self.queryResultLimits.first
                ) { limit in
                    Text(Self.rowsTitle(limit ?? 0))
                }
            } label: {
                Text("Query result limit")
                Text(
                    """
                    SELECT queries without their own LIMIT stop at this many rows. The editor text never changes. \
                    Fetch All and Execute Without Limit skip it once.
                    """
                )
            }
            .accessibilityIdentifier("data-result-limit-picker")

            Picker(selection: $settings.resultSetsKeptPerRun) {
                SettingsChoiceItems(Self.resultSetsKept, including: settings.resultSetsKeptPerRun) { count in
                    Text(Self.resultSetsKeptTitle(count))
                }
            } label: {
                Text("Results kept per run")
                Text("A run that returns more keeps only the newest. Pinned results always stay.")
            }
            .accessibilityIdentifier("data-results-kept-picker")
        } header: {
            Text("Pages and Limits")
        }
    }

    // Limit and switch change together in one write, so neither is seen without the other.
    static func queryResultLimitBinding(_ settings: Binding<DataGridSettings>) -> Binding<Int?> {
        Binding(
            get: { settings.wrappedValue.queryResultLimit },
            set: { settings.wrappedValue = settings.wrappedValue.withQueryResultLimit($0) }
        )
    }

    static func rowsTitle(_ count: Int) -> String {
        String(localized: "\(count) rows")
    }

    static func exactCountTitle(_ threshold: Int) -> String {
        threshold == Int.max ? String(localized: "Always") : String(localized: "Under \(threshold) rows")
    }

    static func resultSetsKeptTitle(_ count: Int) -> String {
        count == 0 ? String(localized: "No limit") : SettingsFormat.count(count)
    }
}

// Each row below follows only its own category, so a write elsewhere never redraws the grid rows.
private struct DataFontRows: View {
    @ObservedObject var typography: SettingsSlice<TypographySettings>

    var body: some View {
        TypographyRows(domain: .dataGrid, typography: $typography.value)
    }
}

private struct ColorValuesByTypeToggle: View {
    @ObservedObject var valueColors: SettingsSlice<ValueColorSettings>

    var body: some View {
        // ThemeValueColorsNote names this label.
        Toggle(isOn: $valueColors.value.colorsValuesByType) {
            Text("Color values by type")
            Text("Draws strings, numbers, dates and other typed values in the theme's Values colors.")
        }
        .accessibilityIdentifier("color-values-by-type-toggle")
    }
}

private struct JSONViewModePicker: View {
    @ObservedObject var editor: SettingsSlice<EditorSettings>

    var body: some View {
        Picker("Default JSON view", selection: $editor.value.jsonViewerPreferredMode) {
            Text("Text").tag(JSONViewMode.text)
            Text("Tree").tag(JSONViewMode.tree)
        }
        .accessibilityIdentifier("data-json-view-picker")
    }
}
