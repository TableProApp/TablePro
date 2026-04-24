//
//  FeedbackView.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

struct FeedbackView: View {
    @Bindable var viewModel: FeedbackViewModel

    enum FocusField {
        case title, description, steps, expected
    }

    @FocusState private var focusedField: FocusField?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if case .success(let url, let number) = viewModel.submissionResult {
                successView(issueUrl: url, issueNumber: number)
            } else {
                formView
            }
        }
        .frame(width: 520, height: 580)
    }

    // MARK: - Form

    private var formView: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("Type", selection: $viewModel.feedbackType) {
                        ForEach(FeedbackType.allCases, id: \.self) { type in
                            Label(type.displayName, systemImage: type.iconName)
                                .tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    TextField("Title", text: $viewModel.title, prompt: Text(String(localized: "Brief summary of the issue")))
                        .focused($focusedField, equals: .title)

                    LabeledContent("Description") {
                        TextEditor(text: $viewModel.description)
                            .font(.system(.body))
                            .frame(minHeight: 60)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .focused($focusedField, equals: .description)
                    }
                }

                if viewModel.feedbackType == .bugReport {
                    Section {
                        LabeledContent("Steps to Reproduce") {
                            TextEditor(text: $viewModel.stepsToReproduce)
                                .font(.system(.body))
                                .frame(minHeight: 44)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                )
                                .focused($focusedField, equals: .steps)
                        }

                        LabeledContent("Expected Behavior") {
                            TextEditor(text: $viewModel.expectedBehavior)
                                .font(.system(.body))
                                .frame(minHeight: 44)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                                )
                                .focused($focusedField, equals: .expected)
                        }
                    }
                }

                Section("Attachments") {
                    attachmentsContent
                }

                Section {
                    Toggle("Include diagnostics", isOn: $viewModel.includeDiagnostics)

                    if viewModel.includeDiagnostics {
                        Text(viewModel.diagnostics.formattedSummary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } footer: {
                    Text("Includes app version, macOS version, and installed plugins only.")
                }
            }
            .formStyle(.grouped)

            Divider()

            footerView
        }
        .animation(.default, value: viewModel.feedbackType)
        .onAppear { focusedField = .title }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Attachments

    private var attachmentsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumbnail(attachment)
                        }
                    }
                }
                .frame(height: 72)
            }

            HStack(spacing: 8) {
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!viewModel.canAddAttachment)

                Button {
                    viewModel.captureWindow()
                } label: {
                    Label("Capture Window", systemImage: "camera.viewfinder")
                }
                .disabled(!viewModel.canAddAttachment)

                Button {
                    Task { await viewModel.browseFiles() }
                } label: {
                    Label("Browse...", systemImage: "folder")
                }
                .disabled(!viewModel.canAddAttachment)

                Spacer()

                if !viewModel.attachments.isEmpty {
                    Text("\(viewModel.attachments.count)/\(5)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func attachmentThumbnail(_ attachment: FeedbackAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: attachment.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 80, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )

            Button {
                viewModel.removeAttachment(attachment)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white, Color(nsColor: .systemGray))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
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
        VStack(spacing: 8) {
            if case .failure(let error) = viewModel.submissionResult {
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            HStack {
                Button("Cancel") {
                    NSApp.windows.first { $0.identifier?.rawValue == "feedback" }?.close()
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Success

    private func successView(issueUrl: URL, issueNumber: Int) -> some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Color(nsColor: .systemGreen))

            Text("Feedback submitted!")
                .font(.title2)
                .fontWeight(.semibold)

            Text(String(format: String(localized: "Created as GitHub issue #%d"), issueNumber))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link(destination: issueUrl) {
                    Label("View on GitHub", systemImage: "arrow.up.right")
                }
                .buttonStyle(.borderedProminent)
            }

            HStack(spacing: 16) {
                Button("Submit Another") {
                    viewModel.resetForNewSubmission()
                }
                .font(.subheadline)

                Button("Close") {
                    NSApp.windows.first { $0.identifier?.rawValue == "feedback" }?.close()
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
