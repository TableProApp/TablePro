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

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    textField("Title", text: $viewModel.title, prompt: "Brief summary of the issue")
                        .focused($focusedField, equals: .title)

                    textArea("Description", text: $viewModel.description, minHeight: 72)
                        .focused($focusedField, equals: .description)

                    if viewModel.feedbackType == .bugReport {
                        textArea("Steps to Reproduce", text: $viewModel.stepsToReproduce, minHeight: 48)
                            .focused($focusedField, equals: .steps)

                        textArea("Expected Behavior", text: $viewModel.expectedBehavior, minHeight: 48)
                            .focused($focusedField, equals: .expected)
                    }

                    attachmentsSection

                    diagnosticsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()

            footerView
        }
        .animation(.default, value: viewModel.feedbackType)
        .onAppear { focusedField = .title }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Reusable Fields

    private func textField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("", text: text, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func textArea(_ label: String, text: Binding<String>, minHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: text)
                .font(.body)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attachments")
                .font(.callout)
                .foregroundStyle(.secondary)

            if !viewModel.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumbnail(attachment)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Button {
                    viewModel.pasteFromClipboard()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.callout)
                }
                .controlSize(.small)
                .disabled(!viewModel.canAddAttachment)

                Button {
                    viewModel.captureWindow()
                } label: {
                    Label("Capture Window", systemImage: "camera.viewfinder")
                        .font(.callout)
                }
                .controlSize(.small)
                .disabled(!viewModel.canAddAttachment)

                Button {
                    Task { await viewModel.browseFiles() }
                } label: {
                    Label("Browse...", systemImage: "folder")
                        .font(.callout)
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
        ZStack(alignment: .topTrailing) {
            Image(nsImage: attachment.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 56)
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
                    .symbolRenderingMode(.palette)
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

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $viewModel.includeDiagnostics) {
                Text("Include diagnostics")
                    .font(.callout)
            }

            if viewModel.includeDiagnostics {
                Text(viewModel.diagnostics.formattedSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
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
                    NSApp.windows.first { $0.identifier?.rawValue == "feedback" }?.close()
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
