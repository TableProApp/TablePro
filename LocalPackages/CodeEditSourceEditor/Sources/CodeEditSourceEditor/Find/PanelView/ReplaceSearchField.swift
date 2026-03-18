//
//  ReplaceSearchField.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/18/25.
//

import SwiftUI

/// A SwiftUI view that provides the replace text field for the find panel.
///
/// The `ReplaceSearchField` view is responsible for:
/// - Displaying and managing the replace text input field
/// - Showing a visual indicator (pencil icon) for the replace field
/// - Adapting its layout between condensed and full modes
/// - Maintaining focus state for keyboard navigation
///
/// The view is only shown when the find panel is in replace mode and adapts its layout
/// based on the `condensed` parameter to match the find field's appearance.
struct ReplaceSearchField: View {
    @ObservedObject var viewModel: FindPanelViewModel
    @FocusState.Binding var focus: FindPanelView.FindPanelFocus?
    @Binding var findModePickerWidth: CGFloat
    var condensed: Bool

    var body: some View {
        PanelTextField(
            "Text",
            text: $viewModel.replaceText,
            leadingAccessories: {
                if condensed {
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                } else {
                    HStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                                .padding(.trailing, 5)
                            Text("With")
                        }
                        .frame(width: findModePickerWidth, alignment: .leading)
                        Divider()
                    }
                }
            },
            clearable: true
        )
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .focused($focus, equals: .replace)
    }
}

#Preview("Replace Search Field - Full") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    ReplaceSearchField(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.replaceText = "replacement"
            return vm
        }(),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: false
    )
    .frame(width: 300)
    .padding()
}

#Preview("Replace Search Field - Condensed") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    ReplaceSearchField(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.replaceText = "replacement"
            return vm
        }(),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: true
    )
    .frame(width: 200)
    .padding()
}

#Preview("Replace Search Field - Empty") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    ReplaceSearchField(
        viewModel: FindPanelViewModel(target: MockFindPanelTarget()),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: false
    )
    .frame(width: 300)
    .padding()
}
