//
//  DialogFooter.swift
//  TablePro
//

import SwiftUI

/// Dialog buttons belong together at the trailing edge with the default action last. Splitting
/// Cancel to the leading edge is the pattern macOS reserves for a button that is not part of the
/// dialog's decision, such as Help, so a Cancel parked there reads as unrelated to the sheet.
internal struct DialogFooter<Auxiliary: View, Actions: View>: View {
    private let auxiliary: Auxiliary
    private let actions: Actions

    internal init(
        @ViewBuilder auxiliary: () -> Auxiliary,
        @ViewBuilder actions: () -> Actions
    ) {
        self.auxiliary = auxiliary()
        self.actions = actions()
    }

    internal var body: some View {
        HStack(spacing: 12) {
            auxiliary
            Spacer(minLength: 12)
            actions
        }
    }
}

internal extension DialogFooter where Auxiliary == EmptyView {
    init(@ViewBuilder actions: () -> Actions) {
        self.init(auxiliary: { EmptyView() }, actions: actions)
    }
}
