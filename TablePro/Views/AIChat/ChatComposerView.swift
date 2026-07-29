//
//  ChatComposerView.swift
//  TablePro
//

import SwiftUI
import UniformTypeIdentifiers

struct ChatComposerView: View {
    @Binding var text: String
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    @Bindable var mentionState: MentionPopoverState
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onAttach: (ContextItem) -> Void
    let acceptsImages: Bool
    let onAttachImages: ([ChatImageInput]) -> Void
    let onImageAttachmentFailed: (String) -> Void

    @State private var isFocused: Bool = false
    @State private var isCommittingMention = false
    @State private var isDropTargeted: Bool = false

    init(
        text: Binding<String>,
        placeholder: String,
        minLines: Int,
        maxLines: Int,
        mentionState: MentionPopoverState,
        onTextChange: @escaping (String, Int) -> Void,
        onSubmit: @escaping () -> Void,
        onAttach: @escaping (ContextItem) -> Void,
        acceptsImages: Bool = false,
        onAttachImages: @escaping ([ChatImageInput]) -> Void = { _ in },
        onImageAttachmentFailed: @escaping (String) -> Void = { _ in }
    ) {
        self._text = text
        self.placeholder = placeholder
        self.minLines = minLines
        self.maxLines = maxLines
        self.mentionState = mentionState
        self.onTextChange = onTextChange
        self.onSubmit = onSubmit
        self.onAttach = onAttach
        self.acceptsImages = acceptsImages
        self.onAttachImages = onAttachImages
        self.onImageAttachmentFailed = onImageAttachmentFailed
    }

    var body: some View {
        let composerCore = ChatComposerTextView(
            text: $text,
            isFocused: $isFocused,
            placeholder: placeholder,
            minLines: minLines,
            maxLines: maxLines,
            isCommittingMention: isCommittingMention,
            acceptsImages: acceptsImages,
            onTextChange: { newText, caret in
                guard !isCommittingMention else { return }
                onTextChange(newText, caret)
            },
            onSubmit: { onSubmit() },
            onCommitMention: { commitMentionIfVisible() },
            onArrow: { delta in moveMention(by: delta) },
            onTab: { commitMentionIfVisible() },
            onEscape: { dismissMention() },
            onPasteImageData: handlePastedImageData
        )
        .fixedSize(horizontal: false, vertical: true)
        .background(composerBackground)
        .popover(
            isPresented: popoverBinding,
            attachmentAnchor: .point(.topLeading),
            arrowEdge: .bottom
        ) {
            MentionSuggestionListView(
                state: mentionState,
                onSelect: { commitMention(at: $0) }
            )
        }

        return Group {
            if acceptsImages {
                composerCore
                    .onDrop(
                        of: [UTType.image, UTType.fileURL],
                        isTargeted: $isDropTargeted,
                        perform: handleDrop(providers:)
                    )
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                composerCore
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard acceptsImages, !providers.isEmpty else { return false }
        Task { @MainActor in
            var collected: [ChatImageInput] = []
            var lastError: Error?
            for provider in providers {
                do {
                    collected.append(try await ChatImageConverter.convert(itemProvider: provider))
                } catch {
                    lastError = error
                }
            }
            if !collected.isEmpty {
                onAttachImages(collected)
            } else if let lastError {
                onImageAttachmentFailed(lastError.localizedDescription)
            }
        }
        return true
    }

    private func handlePastedImageData(_ data: Data, _ uti: String) {
        Task { @MainActor in
            do {
                let input = try await ChatImageConverter.convert(data: data, sourceUTI: uti)
                onAttachImages([input])
            } catch {
                onImageAttachmentFailed(error.localizedDescription)
            }
        }
    }

    private var composerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return shape
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                if isFocused {
                    IntelligenceFocusBorder(shape: shape)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                } else {
                    shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }
            }
            .animation(.easeOut(duration: 0.25), value: isFocused)
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { mentionState.isVisible && !mentionState.candidates.isEmpty },
            set: { newValue in
                if !newValue { mentionState.reset() }
            }
        )
    }

    private func commitMentionIfVisible() -> Bool {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else { return false }
        commitMention(at: mentionState.selectedIndex)
        return true
    }

    private func moveMention(by delta: Int) -> Bool {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else { return false }
        mentionState.moveSelection(by: delta)
        return true
    }

    private func dismissMention() -> Bool {
        guard mentionState.isVisible else { return false }
        mentionState.reset()
        return true
    }

    private func commitMention(at index: Int) {
        guard mentionState.candidates.indices.contains(index) else { return }
        let candidate = mentionState.candidates[index]
        let nsText = text as NSString
        let range = mentionState.anchorRange
        guard range.location >= 0, NSMaxRange(range) <= nsText.length else {
            mentionState.reset()
            return
        }
        isCommittingMention = true
        defer { isCommittingMention = false }
        let prefix = nsText.substring(to: range.location)
        let suffix = nsText.substring(from: NSMaxRange(range))
        text = prefix + suffix
        onAttach(candidate.item)
        mentionState.reset()
    }
}

private enum IntelligenceShimmer {
    static let palette: [Color] = [
        Color(red: 1.0, green: 0.404, blue: 0.471),
        Color(red: 1.0, green: 0.553, blue: 0.443),
        Color(red: 1.0, green: 0.729, blue: 0.443),
        Color(red: 0.961, green: 0.725, blue: 0.918),
        Color(red: 0.776, green: 0.525, blue: 1.0),
        Color(red: 0.737, green: 0.510, blue: 0.953),
        Color(red: 0.553, green: 0.624, blue: 1.0)
    ]

    struct Layer: Identifiable {
        let id: Int
        let lineWidth: CGFloat
        let blur: CGFloat
        let opacity: Double
    }

    static let layers: [Layer] = [
        Layer(id: 0, lineWidth: 1.5, blur: 2, opacity: 1.0),
        Layer(id: 1, lineWidth: 5, blur: 4, opacity: 0.75),
        Layer(id: 2, lineWidth: 9, blur: 10, opacity: 0.5),
        Layer(id: 3, lineWidth: 14, blur: 16, opacity: 0.35)
    ]

    static func generateStops() -> [Gradient.Stop] {
        let count = palette.count
        var stops = palette.enumerated().map { index, color in
            Gradient.Stop(color: color, location: Double(index) / Double(count))
        }
        if let first = palette.first {
            stops.append(Gradient.Stop(color: first, location: 1.0))
        }
        return stops
    }
}

private struct IntelligenceFocusBorder<S: Shape>: View {
    let shape: S

    @State private var stops: [Gradient.Stop] = IntelligenceShimmer.generateStops()

    var body: some View {
        ZStack {
            ForEach(IntelligenceShimmer.layers) { layer in
                shape
                    .stroke(
                        AngularGradient(gradient: Gradient(stops: stops), center: .center),
                        lineWidth: layer.lineWidth
                    )
                    .blur(radius: layer.blur)
                    .opacity(layer.opacity)
            }
        }
    }
}
