//
//  FindPanelContent.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 5/2/25.
//

import SwiftUI

/// A SwiftUI view that provides the main content layout for the find and replace panel.
///
/// The `FindPanelContent` view is responsible for:
/// - Arranging the find and replace text fields in a vertical stack
/// - Arranging the control buttons in a vertical stack
/// - Handling the layout differences between find and replace modes
/// - Supporting both full and condensed layouts
///
/// The view is designed to be used within `FindPanelView` and adapts its layout based on the
/// available space and current mode (find or replace).
struct FindPanelContent: View {
    @ObservedObject var viewModel: FindPanelViewModel
    @FocusState.Binding var focus: FindPanelView.FindPanelFocus?
    var findModePickerWidth: Binding<CGFloat>
    var condensed: Bool

    var body: some View {
        HStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 4) {
                FindSearchField(
                    viewModel: viewModel,
                    focus: $focus,
                    findModePickerWidth: findModePickerWidth,
                    condensed: condensed
                )
                if viewModel.mode == .replace {
                    ReplaceSearchField(
                        viewModel: viewModel,
                        focus: $focus,
                        findModePickerWidth: findModePickerWidth,
                        condensed: condensed
                    )
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                FindControls(viewModel: viewModel, condensed: condensed)
                if viewModel.mode == .replace {
                    Spacer(minLength: 0)
                    ReplaceControls(viewModel: viewModel, condensed: condensed)
                }
            }
            .fixedSize()
        }
    }
}
