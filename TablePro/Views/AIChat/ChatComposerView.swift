//
//  ChatComposerView.swift
//  TablePro
//

import SwiftUI

struct ChatComposerView: View {
    @Binding var text: String
    let placeholder: String
    let minLines: Int
    let maxLines: Int
    @Bindable var mentionState: MentionPopoverState
    let onTextChange: (String, Int) -> Void
    let onSubmit: () -> Void
    let onAttach: (ContextItem) -> Void

    @FocusState private var isFocused: Bool
    @State private var isCommittingMention = false

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(minLines...maxLines)
            .focused($isFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(composerBackground)
            .onChange(of: text) { _, newText in
                guard !isCommittingMention else { return }
                onTextChange(newText, (newText as NSString).length)
            }
            .onSubmit(handleSubmit)
            .onKeyPress(.upArrow) { handleArrow(by: -1) }
            .onKeyPress(.downArrow) { handleArrow(by: 1) }
            .onKeyPress(.tab) { handleTab() }
            .onKeyPress(.escape) { handleEscape() }
            .popover(
                isPresented: popoverBinding,
                attachmentAnchor: .point(.bottom),
                arrowEdge: .top
            ) {
                MentionSuggestionListView(
                    state: mentionState,
                    onSelect: { commitMention(at: $0) }
                )
            }
    }

    private var composerBackground: some View {
        let shape = Capsule(style: .continuous)
        return shape
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay {
                if isFocused {
                    IntelligenceFocusBorder(shape: shape)
                        .transition(.opacity)
                } else {
                    shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        .transition(.opacity)
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

    private func handleSubmit() {
        if mentionState.isVisible, !mentionState.candidates.isEmpty {
            commitMention(at: mentionState.selectedIndex)
        } else {
            onSubmit()
        }
    }

    private func handleArrow(by delta: Int) -> KeyPress.Result {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else {
            return .ignored
        }
        mentionState.moveSelection(by: delta)
        return .handled
    }

    private func handleTab() -> KeyPress.Result {
        guard mentionState.isVisible, !mentionState.candidates.isEmpty else {
            return .ignored
        }
        commitMention(at: mentionState.selectedIndex)
        return .handled
    }

    private func handleEscape() -> KeyPress.Result {
        guard mentionState.isVisible else { return .ignored }
        mentionState.reset()
        return .handled
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
        Color(red: 0.737, green: 0.510, blue: 0.953),
        Color(red: 0.961, green: 0.725, blue: 0.918),
        Color(red: 0.553, green: 0.624, blue: 1.0),
        Color(red: 1.0, green: 0.404, blue: 0.471),
        Color(red: 1.0, green: 0.729, blue: 0.443),
        Color(red: 0.776, green: 0.525, blue: 1.0)
    ]

    struct Layer: Identifiable {
        let id: Int
        let lineWidth: CGFloat
        let blur: CGFloat
        let duration: TimeInterval
        let opacity: Double
    }

    static let layers: [Layer] = [
        Layer(id: 0, lineWidth: 1.5, blur: 0, duration: 0.5, opacity: 1.0),
        Layer(id: 1, lineWidth: 5, blur: 4, duration: 0.6, opacity: 0.75),
        Layer(id: 2, lineWidth: 9, blur: 10, duration: 0.8, opacity: 0.5),
        Layer(id: 3, lineWidth: 14, blur: 16, duration: 1.0, opacity: 0.35)
    ]

    static let updateInterval: Duration = .milliseconds(400)

    static func generateStops() -> [Gradient.Stop] {
        let shuffled = palette.shuffled()
        let lastIndex = max(1, shuffled.count - 1)
        return shuffled.enumerated().map { index, color in
            let base = Double(index) / Double(lastIndex)
            let jitter = Double.random(in: -0.05...0.05)
            return Gradient.Stop(color: color, location: min(1, max(0, base + jitter)))
        }
    }
}

private struct IntelligenceFocusBorder<S: Shape>: View {
    let shape: S

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: layer.duration),
                        value: stops
                    )
            }
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: IntelligenceShimmer.updateInterval)
                stops = IntelligenceShimmer.generateStops()
            }
        }
    }
}
