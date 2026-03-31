//
//  QuerySplitView.swift
//  TablePro
//
//  NSSplitView wrapper (NSViewRepresentable) for the query editor / results split.
//  Uses autosaveName for divider position persistence and manual collapse via
//  subview hiding + adjustSubviews().
//

import AppKit
import SwiftUI

struct QuerySplitView<TopContent: View, BottomContent: View>: NSViewRepresentable {
    var isBottomCollapsed: Bool
    var autosaveName: String
    @ViewBuilder var topContent: TopContent
    @ViewBuilder var bottomContent: BottomContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.autosaveName = autosaveName
        splitView.delegate = context.coordinator

        let topHosting = NSHostingView(rootView: topContent)
        topHosting.sizingOptions = [.minSize]

        let bottomHosting = NSHostingView(rootView: bottomContent)
        bottomHosting.sizingOptions = [.minSize]

        splitView.addArrangedSubview(topHosting)
        splitView.addArrangedSubview(bottomHosting)

        context.coordinator.topHosting = topHosting
        context.coordinator.bottomHosting = bottomHosting
        context.coordinator.lastCollapsedState = isBottomCollapsed

        if isBottomCollapsed {
            bottomHosting.isHidden = true
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.topHosting?.rootView = topContent
        context.coordinator.bottomHosting?.rootView = bottomContent

        guard let bottomView = context.coordinator.bottomHosting else { return }
        let wasCollapsed = context.coordinator.lastCollapsedState

        if isBottomCollapsed != wasCollapsed {
            context.coordinator.lastCollapsedState = isBottomCollapsed
            if isBottomCollapsed {
                // Save divider position before collapsing
                if splitView.subviews.count >= 2 {
                    context.coordinator.savedDividerPosition = splitView.subviews[0].frame.height
                }
                // Move divider to bottom edge to collapse
                splitView.setPosition(splitView.bounds.height, ofDividerAt: 0)
                bottomView.isHidden = true
                splitView.display()
            } else {
                bottomView.isHidden = false
                splitView.adjustSubviews()
                // Restore divider position
                if let saved = context.coordinator.savedDividerPosition {
                    splitView.setPosition(saved, ofDividerAt: 0)
                }
                splitView.display()
            }
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var topHosting: NSHostingView<TopContent>?
        var bottomHosting: NSHostingView<BottomContent>?
        var lastCollapsedState = false
        var savedDividerPosition: CGFloat?

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            100
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            splitView.bounds.height - 150
        }

        func splitView(
            _ splitView: NSSplitView,
            canCollapseSubview subview: NSView
        ) -> Bool {
            subview == bottomHosting
        }

        func splitView(
            _ splitView: NSSplitView,
            effectiveRect proposedEffectiveRect: NSRect,
            forDrawnRect drawnRect: NSRect,
            ofDividerAt dividerIndex: Int
        ) -> NSRect {
            // Hide divider when bottom pane is collapsed
            if bottomHosting?.isHidden == true {
                return .zero
            }
            return proposedEffectiveRect
        }

        func splitView(
            _ splitView: NSSplitView,
            shouldHideDividerAt dividerIndex: Int
        ) -> Bool {
            bottomHosting?.isHidden == true
        }
    }
}
