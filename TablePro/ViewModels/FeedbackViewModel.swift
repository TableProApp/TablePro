//
//  FeedbackViewModel.swift
//  TablePro
//

import AppKit
import Foundation
import Observation
import os
import UniformTypeIdentifiers

struct FeedbackAttachment: Identifiable {
    let id = UUID()
    let image: NSImage
}

@MainActor @Observable
final class FeedbackViewModel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "FeedbackViewModel")
    private static let draftKey = "com.TablePro.feedbackDraft"
    private static let maxScreenshotBytes = 2 * 1_024 * 1_024
    private static let maxAttachments = 5

    // MARK: - User-editable state

    var feedbackType: FeedbackType = .bugReport {
        didSet { scheduleDraftSave() }
    }

    var title = "" {
        didSet { scheduleDraftSave() }
    }

    var description = "" {
        didSet { scheduleDraftSave() }
    }

    var stepsToReproduce = "" {
        didSet { scheduleDraftSave() }
    }

    var expectedBehavior = "" {
        didSet { scheduleDraftSave() }
    }

    var includeDiagnostics = true {
        didSet { scheduleDraftSave() }
    }

    var attachments: [FeedbackAttachment] = []

    var canAddAttachment: Bool {
        attachments.count < Self.maxAttachments
    }

    // MARK: - Submission state

    private(set) var isSubmitting = false
    private(set) var submissionResult: SubmissionResult?
    private(set) var diagnostics: FeedbackDiagnostics

    enum SubmissionResult {
        case success(issueUrl: URL, issueNumber: Int)
        case failure(FeedbackError)
    }

    // MARK: - Computed

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
            !description.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var canSubmit: Bool {
        isValid && !isSubmitting
    }

    // MARK: - Draft persistence

    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var isLoadingDraft = false
    @ObservationIgnored var captureTargetWindow: NSWindow?

    // MARK: - Init

    init() {
        self.diagnostics = FeedbackDiagnosticsCollector.collect()
        loadDraft()
    }

    // MARK: - Attachments

    func addImages(_ images: [NSImage]) {
        for image in images {
            guard canAddAttachment else { break }
            attachments.append(FeedbackAttachment(image: image))
        }
    }

    func removeAttachment(_ attachment: FeedbackAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func pasteFromClipboard() {
        guard let images = NSPasteboard.general.readObjects(forClasses: [NSImage.self]) as? [NSImage] else {
            return
        }
        addImages(images)
    }

    func captureWindow() {
        let window = captureTargetWindow ?? NSApp.windows.first(where: {
            $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible
        })
        guard let window, let contentView = window.contentView else { return }

        let bounds = contentView.bounds
        guard let bitmap = contentView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        contentView.cacheDisplay(in: bounds, to: bitmap)

        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        addImages([image])
    }

    func browseFiles() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif, .heic]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Select images to attach")
        let response = await panel.begin()
        guard response == .OK else { return }

        let images = panel.urls.compactMap { NSImage(contentsOf: $0) }
        addImages(images)
    }

    // MARK: - Submission

    func submit() async {
        guard canSubmit else { return }

        isSubmitting = true
        submissionResult = nil
        defer { isSubmitting = false }

        let encodedScreenshots = encodeScreenshots()

        let architectureString: String = {
            #if arch(arm64)
            return "arm64"
            #else
            return "x86_64"
            #endif
        }()

        let request = FeedbackSubmissionRequest(
            feedbackType: feedbackType.rawValue,
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            stepsToReproduce: feedbackType == .bugReport && !stepsToReproduce.trimmingCharacters(in: .whitespaces).isEmpty
                ? stepsToReproduce.trimmingCharacters(in: .whitespaces) : nil,
            expectedBehavior: feedbackType == .bugReport && !expectedBehavior.trimmingCharacters(in: .whitespaces).isEmpty
                ? expectedBehavior.trimmingCharacters(in: .whitespaces) : nil,
            appVersion: diagnostics.appVersion,
            osVersion: diagnostics.osVersion,
            architecture: architectureString,
            databaseType: diagnostics.activeDatabaseType,
            installedPlugins: includeDiagnostics ? diagnostics.installedPlugins : [],
            machineId: includeDiagnostics ? diagnostics.machineId : "",
            screenshots: encodedScreenshots
        )

        do {
            let response = try await FeedbackAPIClient.shared.submitFeedback(request: request)
            if let url = URL(string: response.issueUrl) {
                submissionResult = .success(issueUrl: url, issueNumber: response.issueNumber)
                clearDraft()
                Self.logger.info("Feedback submitted: issue #\(response.issueNumber)")
            } else {
                submissionResult = .failure(.decodingError(URLError(.badURL)))
            }
        } catch let error as FeedbackError {
            submissionResult = .failure(error)
            Self.logger.error("Feedback submission failed: \(error.localizedDescription)")
        } catch {
            submissionResult = .failure(.networkError(error))
            Self.logger.error("Feedback submission failed: \(error.localizedDescription)")
        }
    }

    func clearSubmissionResult() {
        submissionResult = nil
    }

    func resetForNewSubmission() {
        feedbackType = .bugReport
        title = ""
        description = ""
        stepsToReproduce = ""
        expectedBehavior = ""
        attachments = []
        submissionResult = nil
        diagnostics = FeedbackDiagnosticsCollector.collect()
    }

    // MARK: - Private

    private func encodeScreenshots() -> [String] {
        attachments.compactMap { encodeImage($0.image) }
    }

    private func encodeImage(_ image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        var currentImage = bitmap
        var pngData = currentImage.representation(using: .png, properties: [:])

        while let data = pngData, data.count > Self.maxScreenshotBytes {
            let newWidth = Int(Double(currentImage.pixelsWide) * 0.7)
            let newHeight = Int(Double(currentImage.pixelsHigh) * 0.7)
            guard newWidth > 100, newHeight > 100 else { break }

            let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: newWidth,
                pixelsHigh: newHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            guard let resized else { break }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
            currentImage.draw(
                in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight),
                from: .zero,
                operation: .copy,
                fraction: 1.0,
                respectFlipped: false,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            NSGraphicsContext.restoreGraphicsState()

            currentImage = resized
            pngData = currentImage.representation(using: .png, properties: [:])
        }

        return pngData?.base64EncodedString()
    }

    private func scheduleDraftSave() {
        guard !isLoadingDraft else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    private func saveDraft() {
        let draft = FeedbackDraft(
            feedbackType: feedbackType.rawValue,
            title: title,
            description: description,
            stepsToReproduce: stepsToReproduce,
            expectedBehavior: expectedBehavior,
            includeDiagnostics: includeDiagnostics
        )
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: Self.draftKey)
        }
    }

    private func loadDraft() {
        guard let data = UserDefaults.standard.data(forKey: Self.draftKey),
              let draft = try? JSONDecoder().decode(FeedbackDraft.self, from: data) else {
            return
        }
        isLoadingDraft = true
        defer { isLoadingDraft = false }
        feedbackType = FeedbackType(rawValue: draft.feedbackType) ?? .bugReport
        title = draft.title
        description = draft.description
        stepsToReproduce = draft.stepsToReproduce
        expectedBehavior = draft.expectedBehavior
        includeDiagnostics = draft.includeDiagnostics
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: Self.draftKey)
    }
}
