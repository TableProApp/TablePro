//
//  KeychainNoticeView.swift
//  TablePro
//

import SwiftUI

struct KeychainNotice: Identifiable, Equatable {
    let id: String
    let appName: String
    let promptCount: Int

    static func needed(
        for importer: any ForeignAppImporter,
        request: ForeignImportRequest,
        inventory: ForeignAppInventory
    ) -> KeychainNotice? {
        guard request.includePasswords, importer.readsPasswordsFromKeychain, inventory.keychainPrompts > 0 else {
            return nil
        }
        return KeychainNotice(id: importer.id, appName: importer.displayName, promptCount: inventory.keychainPrompts)
    }

    var title: String {
        String(localized: "macOS will ask for your login password")
    }

    var message: String {
        let template = String(
            localized: """
                Importing passwords from %1$@ reads up to %2$d keychain items. \
                macOS prompts for your login password once per item because each is owned by %1$@. \
                Click Always Allow on each prompt to grant TablePro permanent access. \
                Cancel any prompt to skip the rest.
                """
        )
        return String(format: template, appName, promptCount)
    }
}

struct KeychainNoticeView: View {
    let notice: KeychainNotice
    let onContinue: () -> Void
    let onCancel: () -> Void

    init(notice: KeychainNotice, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.notice = notice
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: notice.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: notice.message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("keychain-notice-cancel")
                Button(String(localized: "Continue"), action: onContinue)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("keychain-notice-continue")
            }
        }
        .padding(20)
    }
}
