//
//  PendingStateOverlay.swift
//  TablePro
//

import SwiftUI

internal struct PendingStateOverlay<Editor: View>: View {
    let isPendingNull: Bool
    let isPendingDefault: Bool
    var minHeight: CGFloat?
    @ViewBuilder let editor: () -> Editor

    var body: some View {
        if isPendingNull || isPendingDefault {
            Text(isPendingNull ? "NULL" : "DEFAULT")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            editor()
        }
    }
}
