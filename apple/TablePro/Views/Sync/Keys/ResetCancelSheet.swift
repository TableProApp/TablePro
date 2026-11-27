//
//  ResetCancelSheet.swift
//  TablePro
//

import SwiftUI
import TableProFFI

// A device that is not certified at the current `av` cancels a reset only with the recovery key, whose identity key
// signs the cancel (core ADR 0056, Reset, Cancel).
internal struct ResetCancelSheet: View {
    @ObservedObject var model: ResetKeysModel
    let reset: PendingResetInfo

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cancel the Reset with Your Recovery Key")
                    .font(.headline)
                Text("Type your recovery key. Hyphens and spaces don't matter.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(String(localized: "Recovery key"), text: $recoveryKey)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .disabled(model.work != nil)
            }
            .padding(20)

            Divider()

            DialogFooter {
                Button(String(localized: "Close"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Cancel Reset")) {
                    Task {
                        let key = recoveryKey
                        recoveryKey = ""
                        if await model.cancel(reset, recoveryKey: key) { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recoveryKey.trimmingCharacters(in: .whitespaces).isEmpty || model.work != nil)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
