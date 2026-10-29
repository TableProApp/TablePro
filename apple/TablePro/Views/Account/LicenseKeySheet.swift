//
//  LicenseKeySheet.swift
//  TablePro
//

import SwiftUI

// Use License Key…: a key an older build saved here is offered filled in, and deleted once it is exchanged.
internal struct LicenseKeySheet: View {
    let storedKey: String?
    let signedInEmail: String?
    let isWorking: Bool
    let onUse: (String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var key: String
    @State private var failure: String?
    @FocusState private var isFieldFocused: Bool

    init(storedKey: String?, signedInEmail: String?, isWorking: Bool, onUse: @escaping (String) async -> String?) {
        self.storedKey = storedKey
        self.signedInEmail = signedInEmail
        self.isWorking = isWorking
        self.onUse = onUse
        _key = State(initialValue: storedKey ?? "")
    }

    private var trimmedKey: String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Use a license key")
                    .font(.headline)

                Text("TablePro signs this Mac in to the account the key belongs to. Keys from older versions of TablePro work here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let signedInEmail {
                    Text(String(format: String(localized: "This replaces %@ on this Mac."), signedInEmail))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            TextField(String(localized: "License key"), text: $key, prompt: Text(verbatim: "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .focused($isFieldFocused)
                .labelsHidden()
                .accessibilityLabel(Text("License key"))
                .accessibilityIdentifier("license-key-field")
                .onSubmit(use)

            if storedKey != nil, trimmedKey == storedKey {
                Text("An older version of TablePro saved this key on this Mac. It is deleted once it is used.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("license-key-error")
            }

            HStack {
                Spacer()

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Checking the license key"))
                }

                Button(String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(String(localized: "Use Key"), action: use)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKey.isEmpty || isWorking)
                    .accessibilityIdentifier("license-key-use")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { isFieldFocused = true }
    }

    private func use() {
        guard !trimmedKey.isEmpty, !isWorking else { return }
        failure = nil
        let key = trimmedKey
        Task {
            failure = await onUse(key)
        }
    }
}
