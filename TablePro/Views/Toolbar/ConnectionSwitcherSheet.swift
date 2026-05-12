//
//  ConnectionSwitcherSheet.swift
//  TablePro
//

import SwiftUI

struct ConnectionSwitcherSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ConnectionSwitcherPopover(onDismiss: { dismiss() })
            .frame(width: 420, height: 520)
    }
}
