//
//  IdealWidthCap.swift
//  TablePro
//

import SwiftUI

// `.frame(maxWidth:)` centres a narrower pop-up in the whole cap and `.fixedSize()` never shrinks in a narrow pane.
struct IdealWidthCap: Layout {
    var maximum: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(ProposedViewSize(width: width(of: child, proposal: proposal), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    private func width(of child: LayoutSubview, proposal: ProposedViewSize) -> CGFloat {
        min(child.sizeThatFits(.unspecified).width, maximum, proposal.width ?? .infinity)
    }
}
