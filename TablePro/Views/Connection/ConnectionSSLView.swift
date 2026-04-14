//
//  ConnectionSSLView.swift
//  TablePro
//
//  Created by Ngo Quoc Dat on 31/3/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ConnectionSSLView: View {
    @Binding var sslMode: SSLMode
    @Binding var sslCaCertPath: String
    @Binding var sslClientCertPath: String
    @Binding var sslClientKeyPath: String

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "SSL Mode"), selection: $sslMode) {
                    ForEach(SSLMode.allCases) { mode in
                        Text(mode.displayLabel).tag(mode)
                    }
                }
            }

            if sslMode != .disabled {
                Section {
                    Text(sslMode.description)
                        .foregroundStyle(.secondary)
                }

                if sslMode == .verifyCa || sslMode == .verifyIdentity {
                    Section(String(localized: "CA Certificate")) {
                        LabeledContent(String(localized: "CA Cert")) {
                            HStack {
                                TextField(
                                    "", text: $sslCaCertPath, prompt: Text("/path/to/ca-cert.pem"))
                                Button(String(localized: "Browse")) {
                                    browseForCertificate(binding: $sslCaCertPath)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section(String(localized: "Client Certificates (Optional)")) {
                    LabeledContent(String(localized: "Client Cert")) {
                        HStack {
                            TextField(
                                "", text: $sslClientCertPath,
                                prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientCertPath)
                            }
                            .controlSize(.small)
                        }
                    }
                    LabeledContent(String(localized: "Client Key")) {
                        HStack {
                            TextField(
                                "", text: $sslClientKeyPath,
                                prompt: Text(String(localized: "(optional)")))
                            Button(String(localized: "Browse")) {
                                browseForCertificate(binding: $sslClientKeyPath)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func browseForCertificate(binding: Binding<String>) {
        guard let window = NSApp.keyWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.showsHiddenFiles = true

        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                binding.wrappedValue = url.path(percentEncoded: false)
            }
        }
    }
}
