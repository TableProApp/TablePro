//
//  SidebarFooterBar.swift
//  TablePro
//

import SwiftUI

internal struct SidebarFooterBar<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    internal init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    internal var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                leading
                SupportPromptLink()
                    .font(.caption)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

internal extension SidebarFooterBar where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() })
    }
}
