import SwiftUI

/// The two font domains, each on the pane that owns the surfaces it applies to. They used to live
/// inside the theme file, so a zoom shortcut rewrote a whole theme, and a font edit on a built-in
/// forked it into a copy.
internal struct TypographySection: View {
    internal enum Domain {
        case editor
        case dataGrid

        internal var title: String {
            switch self {
            case .editor: return String(localized: "Editor Font")
            case .dataGrid: return String(localized: "Data Grid Font")
            }
        }

        internal var caption: String {
            switch self {
            case .editor:
                return String(localized: "Applies to the SQL editor, the JSON viewer's Text mode, and the previews.")
            case .dataGrid:
                return String(localized: "Applies to grid cells, the inspector, cell popovers and the row diff.")
            }
        }
    }

    internal let domain: Domain
    @Binding internal var settings: TypographySettings

    internal var body: some View {
        Section {
            Picker(String(localized: "Family:"), selection: familyBinding) {
                ForEach(EditorFontResolver.availableMonospacedFamilies) { family in
                    Text(family.displayName).tag(family.id)
                }
            }

            Picker(String(localized: "Size:"), selection: sizeBinding) {
                ForEach(TypographySettings.sizeRange, id: \.self) { size in
                    Text(verbatim: "\(size) pt").tag(size)
                }
            }
        } header: {
            Text(domain.title)
        } footer: {
            Text(domain.caption)
        }
    }

    private var familyBinding: Binding<String> {
        switch domain {
        case .editor: return $settings.editorFontFamily
        case .dataGrid: return $settings.dataGridFontFamily
        }
    }

    private var sizeBinding: Binding<Int> {
        switch domain {
        case .editor: return $settings.editorFontSize
        case .dataGrid: return $settings.dataGridFontSize
        }
    }
}
