//
//  PendingStateOverlay.swift
//  TablePro
//

import SwiftUI

struct PendingStateOverlay<Editor: View>: View {
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
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .disabled(true)
                .overlay {
                    ProgressView()
                        .controlSize(.small)
                }
        } else if isTruncated {
            Text("Failed to load full value")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
        } else if isPendingNull || isPendingDefault {
            Text(isPendingNull ? "NULL" : "DEFAULT")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, design: .monospaced))
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
