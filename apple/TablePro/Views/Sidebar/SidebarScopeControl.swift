//
//  SidebarScopeControl.swift
//  TablePro
//

import AppKit

/// Which list the sidebar shows, as its own row above the filter field.
///
/// It sits over the list it switches, where Xcode keeps its navigator chooser, rather than in the
/// titlebar. In the toolbar it held two permanent hit targets in a row that also has to carry the
/// connection, its container and the content commands, and it answered for a pane the window could
/// have collapsed.
///
/// Worded segments rather than glyphs. The toolbar version drew `list.bullet` and `star`, and with
/// no description on either image VoiceOver announced them as "List" and "favorite". Measured on
/// macOS 27, a worded control publishes a radio group whose two radio buttons carry the segments'
/// own labels, "Tables" and "Favorites", so it cannot name itself wrongly.
///
/// The words fit in every language the app ships. Measured at the sidebar's 280pt minimum, which
/// leaves the row 260pt inside its insets, the widest is Turkish at 238pt, English needs 158pt and
/// Simplified Chinese 100pt.
///
/// On macOS 27 it takes the tabs role AppKit gives "tab-based navigation and content selection",
/// at small size. Measured there, a regular control in a sidebar draws a glass capsule whatever
/// its style or role; small with the tabs role draws a flat track with a neutral raised thumb.
/// Small without the role would fill the thumb with the accent color, which marks a value choice,
/// so earlier releases keep the regular control.
@MainActor
internal final class SidebarScopeControl: NSSegmentedControl {
    internal static let tabs: [SidebarTab] = [.tables, .favorites]

    internal init() {
        super.init(frame: .zero)
        segmentCount = Self.tabs.count
        trackingMode = .selectOne
        segmentDistribution = .fillEqually
        controlSize = .regular
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            role = .tabs
            controlSize = .small
        }
        #endif
        for (index, tab) in Self.tabs.enumerated() {
            setLabel(Self.title(for: tab), forSegment: index)
        }
        setAccessibilityIdentifier("sidebar-scope")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarScopeControl does not support NSCoder init")
    }

    /// Nil draws no segment selected, which is the state a window with no connection shows.
    internal var selectedTab: SidebarTab? {
        get {
            Self.tabs.indices.contains(selectedSegment) ? Self.tabs[selectedSegment] : nil
        }
        set {
            let index = newValue.flatMap { Self.tabs.firstIndex(of: $0) } ?? -1
            guard selectedSegment != index else { return }
            selectedSegment = index
        }
    }

    internal static func title(for tab: SidebarTab) -> String {
        switch tab {
        case .tables:
            String(localized: "Tables")
        case .favorites:
            String(localized: "Favorites")
        }
    }
}
