//
//  FeedbackView.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

struct FeedbackView: View {
    @Bindable var viewModel: FeedbackViewModel

    @FocusState private var focusedField: FocusField?
    @State private var isDropTargeted = false
    @State private var showDiagnosticsDetail = false

    enum FocusField {
        case title, description, steps, expected
    }

    var body: some View {
        Group {
            if case .success(let url, let number) = viewModel.submissionResult {
                successView(issueUrl: url, issueNumber: number)
            } else {
                formView
            }
        }
        .frame(width: 480)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(spacing: 0) {
            Picker("", selection: $viewModel.feedbackType) {
                ForEach(FeedbackType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)

            Form {
                Section {
                    TextField(
                        "Title",
                        text: $viewModel.title,
                        prompt: Text(String(localized: "Brief summary of the issue"))
                    )
                    .focused($focusedField, equals: .title)
                }

                Section {
                    TextEditor(text: $viewModel.description)
                        .font(.body)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .description)
                } header: {
                    Text("Description")
                }

                if viewModel.feedbackType == .bugReport {
                    Section {
                        TextEditor(text: $viewModel.stepsToReproduce)
                            .font(.body)
                            .frame(minHeight: 48)
                            .scrollContentBackground(.hidden)
                            .focused($focusedField, equals: .steps)
                    } header: {
                        Text("Steps to Reproduce")
                    }

                    Section {
                        TextEditor(text: $viewModel.expectedBehavior)
                            .font(.body)
                            .frame(minHeight: 48)
                            .scrollContentBackground(.hidden)
                            .focused($focusedField, equals: .expected)
                    } header: {
                        Text("Expected Behavior")
                    }
                }

                Section("Attachments") {
                    attachmentsContent
                }

                Section {
                    Toggle("Include diagnostics", isOn: $viewModel.includeDiagnostics)

                    if viewModel.includeDiagnostics {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(viewModel.diagnostics.formattedSummary)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)

                            DisclosureGroup(isExpanded: $showDiagnosticsDetail) {
                                Text(viewModel.diagnostics.installedPlugins.joined(separator: ", "))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } label: {
                                Text(viewModel.diagnostics.pluginsSummary)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            footerView
        }
        .onAppear { focusedField = .title }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Attachments

    private var attachmentsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumbnail(attachment)
                        }
                    }
                }
                .frame(height: 60)
            }

            HStack(spacing: 6) {
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .disabled(!viewModel.canAddAttachment)

                Button {
                    viewModel.captureWindow()
                } label: {
                    Label("Capture Window", systemImage: "camera.viewfinder")
                }
                .controlSize(.small)
                .disabled(!viewModel.canAddAttachment)

                Button {
                    Task { await viewModel.browseFiles() }
                } label: {
                    Label("Browse...", systemImage: "folder")
                }
                .controlSize(.small)
                .disabled(!viewModel.canAddAttachment)

                Spacer()

                if !viewModel.attachments.isEmpty {
                    Text("\(viewModel.attachments.count)/5")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func attachmentThumbnail(_ attachment: FeedbackAttachment) -> some View {
        Image(nsImage: attachment.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    viewModel.removeAttachment(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.5))
                }
                .buttonStyle(.plain)
                .padding(2)
            }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            guard viewModel.canAddAttachment else { break }

            if provider.canLoadObject(ofClass: NSImage.self) {
                provider.loadObject(ofClass: NSImage.self) { image, _ in
                    Task { @MainActor in
                        if let nsImage = image as? NSImage {
                            viewModel.addImages([nsImage])
                        }
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let image = NSImage(contentsOf: url) else {
                        return
                    }
                    Task { @MainActor in
                        viewModel.addImages([image])
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 6) {
            if case .failure(let error) = viewModel.submissionResult {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }

            HStack {
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if viewModel.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task { await viewModel.submit() }
                } label: {
                    Text(viewModel.isSubmitting ? String(localized: "Submitting...") : String(localized: "Submit"))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSubmit)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Success

    private func successView(issueUrl: URL, issueNumber: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color(nsColor: .systemGreen))

            Text("Feedback submitted!")
                .font(.title3)
                .fontWeight(.semibold)

            Text(String(format: String(localized: "Created as GitHub issue #%d"), issueNumber))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Link(destination: issueUrl) {
                Label("View on GitHub", systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 16) {
                Button("Submit Another") {
                    viewModel.resetForNewSubmission()
                }
                .font(.subheadline)

                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .frame(minHeight: 300)
    }
}
