//
//  ReplaceControls.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 4/30/25.
//

import SwiftUI

/// A SwiftUI view that provides the replace controls for the find panel.
///
/// The `ReplaceControls` view is responsible for:
/// - Displaying replace and replace all buttons
/// - Managing button states based on find text and match count
/// - Adapting button appearance between condensed and full layouts
/// - Providing tooltips for button actions
/// - Handling replace operations through the view model
///
/// The view is only shown when the find panel is in replace mode and works in conjunction
/// with the replace text field to perform text replacements.
struct ReplaceControls: View {
    @ObservedObject var viewModel: FindPanelViewModel
    var condensed: Bool

    var shouldDisableSingle: Bool {
        !viewModel.isFocused || viewModel.findText.isEmpty || viewModel.matchesEmpty
    }

    var shouldDisableAll: Bool {
        viewModel.findText.isEmpty || viewModel.matchesEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            ControlGroup {
                Button {
                    viewModel.replace()
                } label: {
                    Group {
                        if condensed {
                            Image(systemName: "arrow.turn.up.right")
                        } else {
                            Text("Replace")
                        }
                    }
                    .opacity(shouldDisableSingle ? 0.33 : 1)
                }
                .help(condensed ? "Replace" : "")
                .disabled(shouldDisableSingle)
                .frame(maxWidth: .infinity)

                Divider().overlay(Color(nsColor: .tertiaryLabelColor))

                Button {
                    viewModel.replaceAll()
                } label: {
                    Group {
                        if condensed {
                            Image(systemName: "text.insert")
                        } else {
                            Text("All")
                        }
                    }
                    .opacity(shouldDisableAll ? 0.33 : 1)
                }
                .help(condensed ? "Replace All" : "")
                .disabled(shouldDisableAll)
                .frame(maxWidth: .infinity)
            }
            .controlGroupStyle(PanelControlGroupStyle())
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("Replace Controls - Full") {
    ReplaceControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.replaceText = "replacement"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        condensed: false
    )
    .padding()
}

#Preview("Replace Controls - Condensed") {
    ReplaceControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.replaceText = "replacement"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        condensed: true
    )
    .padding()
}

#Preview("Replace Controls - No Matches") {
    ReplaceControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.replaceText = "replacement"
            return vm
        }(),
        condensed: false
    )
    .padding()
}
