//
//  ViewSwitcherStyle.swift
//  TablePro
//

import SwiftUI

/// Measured on macOS 27, small `.tabs` draws a flat track with a raised neutral thumb, the look Apple
/// gives tab navigation, where small `.segmented` fills the thumb with the accent and reads as a value.
///
/// It also publishes a tab group rather than a radio group, so a UI test finds the control by its
/// identifier or its segments, which stay radio buttons named by their labels.
private struct ViewSwitcherStyle: ViewModifier {
    func body(content: Content) -> some View {
        switcher(content)
            .controlSize(.small)
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
    /// For a picker that switches what a pane bar, status bar, viewer strip or inspector shows. A
    /// picker that sets a value stays `.segmented`.
    func viewSwitcherStyle() -> some View {
        modifier(ViewSwitcherStyle())
    }
}
