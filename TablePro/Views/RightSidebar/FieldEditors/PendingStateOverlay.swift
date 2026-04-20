//
//  PendingStateOverlay.swift
//  TablePro
//

import SwiftUI

internal struct PendingStateOverlay<Editor: View>: View {
    let isPendingNull: Bool
    let isPendingDefault: Bool
    let isLoadingFullValue: Bool
    let isTruncated: Bool
    var minHeight: CGFloat?
    @ViewBuilder let editor: () -> Editor

    var body: some View {
        if isLoadingFullValue {
            TextField("", text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(true)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        } else if isTruncated {
            TextField(String(localized: "Value excluded from query"), text: .constant(""))
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(true)
        } else if isPendingNull || isPendingDefault {
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
