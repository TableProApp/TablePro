//
//  SQLReviewSheet.swift
//  TablePro
//

import SwiftUI

struct SQLReviewSheet: View {
    @Binding var isPresented: Bool
    @Environment(\.dismiss) private var dismiss

    let statements: [String]
    let databaseType: DatabaseType

    var body: some View {
        VStack(spacing: 0) {
            SQLReviewPopover(statements: statements, databaseType: databaseType)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 320)
    }
}
