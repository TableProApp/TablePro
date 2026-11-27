import SwiftUI

// Fonts are settings, not theme: importing a theme never changes someone's font or size.
internal struct TypographyRows: View {
    internal enum Domain: Sendable {
        case editor
        case dataGrid

        internal var familyTitle: LocalizedStringKey {
            switch self {
            case .editor: "Family"
            case .dataGrid: "Font"
            }
        }

        internal var sizeTitle: LocalizedStringKey {
            switch self {
            case .editor: "Size"
            case .dataGrid: "Font size"
            }
        }

        internal var subtitle: String {
            switch self {
            case .editor:
                String(localized: "The SQL editor, the JSON viewer's Text mode and SQL previews. Applies to this Mac.")
            case .dataGrid:
                String(localized: "Grid cells, the inspector, cell popovers and the row diff. Applies to this Mac.")
            }
        }

        internal func missingFamilyNotice(_ family: String) -> String {
            switch self {
            case .editor:
                String(format: String(localized: "%@ isn't installed. The editor uses System Mono."), family)
            case .dataGrid:
                String(format: String(localized: "%@ isn't installed. Grids use System Mono."), family)
            }
        }

        internal var familyIdentifier: String {
            switch self {
            case .editor: "editor-font-family"
            case .dataGrid: "data-font-family"
            }
        }

        internal var sizeIdentifier: String {
            switch self {
            case .editor: "editor-font-size"
            case .dataGrid: "data-font-size"
            }
        }

        internal func family(of typography: TypographySettings) -> String {
            switch self {
            case .editor: typography.editorFontFamily
            case .dataGrid: typography.dataGridFontFamily
            }
        }

        internal func setFamily(_ family: String, in typography: inout TypographySettings) {
            switch self {
            case .editor: typography.editorFontFamily = family
            case .dataGrid: typography.dataGridFontFamily = family
            }
        }

        // The size ThemeEngine draws, so an out-of-range stored size never leaves the pop-up blank.
        internal func displayedSize(of typography: TypographySettings) -> Int {
            switch self {
            case .editor: typography.clampedEditorFontSize
            case .dataGrid: typography.clampedDataGridFontSize
            }
        }

        internal func setSize(_ size: Int, in typography: inout TypographySettings) {
            switch self {
            case .editor: typography.editorFontSize = size
            case .dataGrid: typography.dataGridFontSize = size
            }
        }
    }

    private let domain: Domain
    @Binding private var typography: TypographySettings
    @ObservedObject private var fonts = MonospacedFontFamilies.shared

    internal init(domain: Domain, typography: Binding<TypographySettings>) {
        self.domain = domain
        self._typography = typography
    }

    internal var body: some View {
        let family = domain.family(of: typography)
        let missing = Self.missingFamily(family, in: fonts.families)

        Picker(selection: Self.familyBinding(domain, of: $typography)) {
            ForEach(fonts.families) { option in
                Text(verbatim: option.displayName).tag(option.id)
            }
            if let missing {
                Divider()
                Text(verbatim: Self.notInstalledTitle(missing)).tag(missing)
            }
        } label: {
            Text(domain.familyTitle)
            if let missing {
                NoticeLabel(domain.missingFamilyNotice(missing), severity: .warning)
                    .font(.subheadline)
            } else {
                Text(domain.subtitle)
            }
        }
        .accessibilityIdentifier(domain.familyIdentifier)

        Picker(selection: Self.sizeBinding(domain, of: $typography)) {
            ForEach(TypographySettings.sizeRange, id: \.self) { size in
                Text("\(size) pt").tag(size)
            }
        } label: {
            Text(domain.sizeTitle)
        }
        .accessibilityIdentifier(domain.sizeIdentifier)
    }

    // A saved family that is gone stays selectable, so the pop-up never draws blank and nothing is rewritten.
    internal static func missingFamily(_ family: String, in families: [FontFamilyOption]) -> String? {
        families.contains { $0.id == family } ? nil : family
    }

    internal static func notInstalledTitle(_ family: String) -> String {
        String(format: String(localized: "%@ (Not Installed)"), family)
    }

    internal static func familyBinding(_ domain: Domain, of typography: Binding<TypographySettings>) -> Binding<String> {
        Binding(
            get: { domain.family(of: typography.wrappedValue) },
            set: { family in domain.setFamily(family, in: &typography.wrappedValue) }
        )
    }

    internal static func sizeBinding(_ domain: Domain, of typography: Binding<TypographySettings>) -> Binding<Int> {
        Binding(
            get: { domain.displayedSize(of: typography.wrappedValue) },
            set: { size in domain.setSize(size, in: &typography.wrappedValue) }
        )
    }
}
