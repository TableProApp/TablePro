//
//  FindControls.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 4/30/25.
//

import SwiftUI

/// A SwiftUI view that provides the navigation controls for the find panel.
///
/// The `FindControls` view is responsible for:
/// - Displaying previous/next match navigation buttons
/// - Showing a done button to dismiss the find panel
/// - Adapting button appearance based on match count
/// - Supporting both condensed and full layouts
/// - Providing tooltips for button actions
///
/// The view is part of the find panel's control section and works in conjunction with
/// the find text field to provide navigation through search results.
struct FindControls: View {
    @ObservedObject var viewModel: FindPanelViewModel
    var condensed: Bool

    var imageOpacity: CGFloat {
        viewModel.matchesEmpty ? 0.33 : 1
    }

    var dynamicPadding: CGFloat {
        condensed ? 0 : 5
    }

    var body: some View {
        HStack(spacing: 4) {
            ControlGroup {
                Button {
                    viewModel.moveToPreviousMatch()
                } label: {
                    Image(systemName: "chevron.left")
                        .opacity(imageOpacity)
                        .padding(.horizontal, dynamicPadding)
                }
                .help("Previous Match")
                .disabled(viewModel.matchesEmpty)

                Divider()
                    .overlay(Color(nsColor: .tertiaryLabelColor))
                Button {
                    viewModel.moveToNextMatch()
                } label: {
                    Image(systemName: "chevron.right")
                        .opacity(imageOpacity)
                        .padding(.horizontal, dynamicPadding)
                }
                .help("Next Match")
                .disabled(viewModel.matchesEmpty)
            }
            .controlGroupStyle(PanelControlGroupStyle())
            .fixedSize()

            Button {
                viewModel.dismiss?()
            } label: {
                Group {
                    if condensed {
                        Image(systemName: "xmark")
                    } else {
                        Text("Done")
                    }
                }
                .help(condensed ? "Done" : "")
                .padding(.horizontal, dynamicPadding)
            }
            .buttonStyle(PanelButtonStyle())
        }
    }
}

#Preview("Find Controls - Full") {
    FindControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        condensed: false
    )
    .padding()
}

#Preview("Find Controls - Condensed") {
    FindControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            vm.findMatches = [NSRange(location: 0, length: 7)]
            vm.currentFindMatchIndex = 0
            return vm
        }(),
        condensed: true
    )
    .padding()
}

#Preview("Find Controls - No Matches") {
    FindControls(
        viewModel: {
            let vm = FindPanelViewModel(target: MockFindPanelTarget())
            vm.findText = "example"
            return vm
        }(),
        condensed: false
    )
    .padding()
}
