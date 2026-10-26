//
//  ViewSwitcherStyle.swift
//  TablePro
//

import SwiftUI

/// Measured on macOS 27, small `.tabs` draws a flat track with a raised neutral thumb, the look Apple
/// gives tab navigation, where small `.segmented` fills the thumb with the accent and reads as a value.
///
/// To accessibility it is then a tab group of tab buttons rather than a radio group of segments.
private struct ViewSwitcherStyle: ViewModifier {
    let controlSize: ControlSize

    func body(content: Content) -> some View {
        switcher(content)
            .controlSize(controlSize)
    }

    @ViewBuilder
    private func switcher(_ content: Content) -> some View {
        #if SDK_MACOS_27
        if #available(macOS 27.0, *) {
            content.pickerStyle(.tabs)
        } else {
            content.pickerStyle(.segmented)
        }
        #else
        content.pickerStyle(.segmented)
        #endif
    }
}

internal extension View {
    /// For a picker that switches what a pane shows: small in a pane bar, status bar, viewer strip or
    /// inspector, regular in a `PaneTabBar`. A picker that sets a value stays `.segmented`.
    func viewSwitcherStyle(_ controlSize: ControlSize = .small) -> some View {
        modifier(ViewSwitcherStyle(controlSize: controlSize))
    }
}

/// The tab row a main-window pane switches its views with, centred over content that runs edge to
/// edge. A bordered tab view boxes and insets the grids these panes hold; the tabs role is the
/// control macOS 27 gives tab navigation, and before it the segmented control is.
internal struct PaneTabBar<Selection: Hashable, Tabs: View>: View {
    let title: String
    @Binding var selection: Selection
    let identifier: String
    @ViewBuilder let tabs: () -> Tabs

    /// Spacers rather than a fixed size, so a pane narrower than the tabs compresses them instead of
    /// pushing the outer ones past its edges.
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Picker(title, selection: $selection, content: tabs)
                .labelsHidden()
                .viewSwitcherStyle(.regular)
                .accessibilityIdentifier(identifier)
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
