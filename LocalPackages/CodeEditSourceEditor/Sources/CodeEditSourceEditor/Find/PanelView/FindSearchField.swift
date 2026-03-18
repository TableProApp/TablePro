//
//  FindSearchField.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/18/25.
//

import SwiftUI

/// A SwiftUI view that provides the search text field for the find panel.
///
/// The `FindSearchField` view is responsible for:
/// - Displaying and managing the find text input field
/// - Showing the find mode picker (find/replace) in both condensed and full layouts
/// - Providing case sensitivity toggle
/// - Displaying match count information
/// - Handling keyboard navigation (Enter to find next)
///
/// The view adapts its layout based on the `condensed` parameter, providing a more compact
/// interface when space is limited.
struct FindSearchField: View {
    @ObservedObject var viewModel: FindPanelViewModel
    @FocusState.Binding var focus: FindPanelView.FindPanelFocus?
    @Binding var findModePickerWidth: CGFloat
    var condensed: Bool

    private var helperText: String? {
        if viewModel.findText.isEmpty {
            nil
        } else if condensed {
            "\(viewModel.matchCount)"
        } else {
            "\(viewModel.matchCount) \(viewModel.matchCount == 1 ? "match" : "matches")"
        }
    }

    var body: some View {
        PanelTextField(
            "Text",
            text: $viewModel.findText,
            leadingAccessories: {
                if condensed {
                    Color.clear
                        .frame(width: 12, height: 12)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            FindModePicker(
                                mode: $viewModel.mode,
                                wrapAround: $viewModel.wrapAround
                            )
                        }
                        .clipped()
                        .overlay(alignment: .trailing) {
                            Image(systemName: "chevron.down")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 5, weight: .black))
                                .padding(.leading, 4).padding(.trailing, -4)
                        }
                } else {
                    HStack(spacing: 0) {
                        FindModePicker(
                            mode: $viewModel.mode,
                            wrapAround: $viewModel.wrapAround
                        )
                        .background(GeometryReader { geometry in
                            Color.clear.onAppear {
                                findModePickerWidth = geometry.size.width
                            }
                            .onChange(of: geometry.size.width) { newWidth in
                                findModePickerWidth = newWidth
                            }
                        })
                        .focusable(false)
                        Divider()
                    }
                }
            },
            trailingAccessories: {
                Divider()
                Toggle(isOn: $viewModel.matchCase, label: {
                    Image(systemName: "textformat")
                        .font(.system(
                            size: 11,
                            weight: viewModel.matchCase ? .bold : .medium
                        ))
                        .foregroundStyle(
                            Color(
                                nsColor: viewModel.matchCase
                                  ? .controlAccentColor
                                  : .labelColor
                            )
                        )
                        .frame(width: 30, height: 20)
                })
                .toggleStyle(.icon)
                Divider()
                FindMethodPicker(method: $viewModel.findMethod, condensed: condensed)
            },
            helperText: helperText,
            clearable: true
        )
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .focused($focus, equals: .find)
        .onSubmit {
            viewModel.moveToNextMatch()
        }
    }
}

#Preview("Find Search Field - Full") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    FindSearchField(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: false
    )
    .frame(width: 300)
    .padding()
}

#Preview("Find Search Field - Condensed") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    FindSearchField(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: true
    )
    .frame(width: 200)
    .padding()
}

#Preview("Find Search Field - Empty") {
    @FocusState var focus: FindPanelView.FindPanelFocus?
    FindSearchField(
        viewModel: FindPanelViewModel(target: MockFindPanelTarget()),
        focus: $focus,
        findModePickerWidth: .constant(100),
        condensed: false
    )
    .frame(width: 300)
    .padding()
}
