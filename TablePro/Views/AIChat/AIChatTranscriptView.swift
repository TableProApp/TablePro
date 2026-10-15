//
//  AIChatTranscriptView.swift
//  TablePro
//

import SwiftUI

/// The conversation in one scroll view, newest at the bottom, following the reply while the reader is at the end.
struct AIChatTranscriptView: View {
    @ObservedObject var viewModel: AIChatViewModel
    let contentWidth: ChatContentWidth

    @State private var tracker = ChatScrollTracker()
    @State private var isPinned = true
    @State private var scrollToBottomRequest = 0
    @State private var viewportHeight: CGFloat = 0

    private static let bottomAnchorID = "chat.bottom.anchor"
    private static let viewportSpace = "chat.viewport"
    private static let contentSpace = "chat.content"
    /// How close to the end still counts as at the end, so a reader a few points short is still followed.
    private static let bottomTolerance: CGFloat = 24

    var body: some View {
        let rows = ChatTranscriptRow.rows(for: viewModel.messages)
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                messageView(for: row.message)
                                    .padding(.top, row.followsReply ? 20 : 4)
                                    .padding(.bottom, 4)
                                    .id(row.message.id)
                            }
                        }
                        bottomEdge(scrollToBottom: { proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom) })
                    }
                    .coordinateSpace(name: Self.contentSpace)
                    .chatColumn(contentWidth)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .coordinateSpace(name: Self.viewportSpace)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    viewportHeight = height
                }
                .modifier(FollowsGrowthAtBottom {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                })
                .onChange(of: viewModel.activeConversationID) { _ in
                    pin()
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: rows.last(where: { $0.message.role == .user })?.message.id) { _ in
                    pin()
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                }
                .onChange(of: scrollToBottomRequest) { _ in
                    withMotion(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
            }

            /// Its own container carries the animation, so the button fades without animating the transcript's
            /// layout when the two change together.
            ZStack {
                if !isPinned {
                    Button {
                        pin()
                        scrollToBottomRequest &+= 1
                    } label: {
                        Image(systemName: "arrow.down")
                            .fontWeight(.semibold)
                    }
                    .controlSize(.large)
                    .modifier(FloatingButtonStyle())
                    .help(String(localized: "Scroll to latest message"))
                    .padding(.bottom, 8)
                    .transition(.opacity)
                    .accessibilityLabel(String(localized: "Scroll to latest message"))
                }
            }
            .motionAnimation(.easeInOut(duration: 0.2), value: isPinned)
        }
        .environmentObject(viewModel)
        .task(id: viewModel.activeConversationID) {
            await MarkdownDocumentCache.shared.prewarm(Self.settledMarkdown(in: viewModel.messages))
        }
    }

    /// The text every row will parse, so opening a long conversation parses it away from the main actor before the
    /// reader scrolls back through it.
    private static func settledMarkdown(in messages: [ChatTurn]) -> [String] {
        messages.reversed().flatMap { message -> [String] in
            if message.role == .user {
                return [message.plainText]
            }
            return message.blocks.compactMap { block in
                guard !block.isStreaming, case .text(let text) = block.kind, !text.isEmpty else { return nil }
                return text
            }
        }
    }

    /// The end of the transcript, outside the lazy stack so it is always built. Its geometry says whether the reader
    /// is at the end and whether the content grew, and changes only when one of those does, not on every scrolled
    /// frame.
    private func bottomEdge(scrollToBottom: @escaping () -> Void) -> some View {
        let viewportHeight = viewportHeight
        return Color.clear
            .frame(height: 1)
            .id(Self.bottomAnchorID)
            .onGeometryChange(for: ChatScrollEdge.self) { geometry in
                ChatScrollEdge(
                    contentHeight: geometry.frame(in: .named(Self.contentSpace)).minY.rounded(),
                    isAtBottom: geometry.frame(in: .named(Self.viewportSpace)).minY
                        <= viewportHeight + Self.bottomTolerance
                )
            } action: { edge in
                let followsGrowth = tracker.pinning.update(with: edge)
                if isPinned != tracker.pinning.isPinned {
                    isPinned = tracker.pinning.isPinned
                }
                guard followsGrowth else { return }
                if #unavailable(macOS 14) {
                    scrollToBottom()
                }
            }
    }

    private func pin() {
        tracker.pinning.pin()
        isPinned = true
    }

    private func messageView(for message: ChatTurn) -> some View {
        let isPausedHere = shouldShowContinue(for: message)
        return AIChatMessageView(
            message: message,
            onRetry: shouldShowRetry(for: message) ? { viewModel.retry() } : nil,
            onRegenerate: shouldShowRegenerate(for: message) ? { viewModel.regenerate() } : nil,
            onEdit: message.role == .user && !viewModel.isStreaming ? { viewModel.editMessage(message) } : nil,
            onContinue: isPausedHere ? { viewModel.continueToolLoop() } : nil,
            onAdjustToolLimit: isPausedHere ? { WindowOpener.shared.openSettings(tab: .ai) } : nil,
            pausedToolCallCount: isPausedHere ? viewModel.toolLimitPauseCount : nil
        )
        .equatable()
    }

    private func shouldShowRetry(for message: ChatTurn) -> Bool {
        message.role == .user
            && message.id == viewModel.messages.last?.id
            && viewModel.lastMessageFailed
            && viewModel.canRetryLastFailure
    }

    private func shouldShowContinue(for message: ChatTurn) -> Bool {
        message.role == .assistant
            && viewModel.isPausedAtToolLimit
            && message.id == viewModel.messages.last(where: { $0.role == .assistant })?.id
    }

    private func shouldShowRegenerate(for message: ChatTurn) -> Bool {
        message.role == .assistant
            && message.id == viewModel.messages.last?.id
            && !viewModel.isStreaming
            && !message.plainText.isEmpty
    }
}

/// One visible turn of the transcript.
struct ChatTranscriptRow: Identifiable {
    let message: ChatTurn
    /// A question that follows a reply opens a new exchange, and gets more room above it.
    let followsReply: Bool

    var id: UUID { message.id }

    /// System turns, and user turns that only carry tool results back to the model, are protocol plumbing rather
    /// than anything the user wrote, so they are left out.
    @MainActor
    static func rows(for messages: [ChatTurn]) -> [ChatTranscriptRow] {
        var rows: [ChatTranscriptRow] = []
        rows.reserveCapacity(messages.count)
        for message in messages where isVisible(message) {
            let followsReply = message.role == .user && rows.last?.message.role == .assistant
            rows.append(ChatTranscriptRow(message: message, followsReply: followsReply))
        }
        return rows
    }

    @MainActor
    private static func isVisible(_ message: ChatTurn) -> Bool {
        guard message.role != .system else { return false }
        guard message.role == .user else { return true }
        return message.blocks.contains { block in
            switch block.kind {
            case .text(let value): return !value.isEmpty
            case .attachment, .image: return true
            case .toolUse, .toolResult, .reasoning, .sqlWalkthrough: return false
            }
        }
    }
}

/// Where the transcript's end sits, as its bottom edge reports it.
struct ChatScrollEdge: Equatable, Sendable {
    /// The edge's offset inside the content, which grows when the content does.
    let contentHeight: CGFloat
    let isAtBottom: Bool
}

/// Whether the transcript follows its end.
///
/// The reader is followed while at the end and left alone once they scroll up. Growth is told apart from scrolling
/// by the content's height: content that grows while the reader was at the end pushes the end out of view for a
/// moment, and that must not read as the reader leaving it.
struct ChatScrollPinning: Equatable {
    private(set) var isPinned = true
    private var contentHeight: CGFloat?

    /// - Returns: Whether the content grew while the reader was at the end, so the view has to follow it.
    mutating func update(with edge: ChatScrollEdge) -> Bool {
        defer { contentHeight = edge.contentHeight }
        /// The first report can come before the transcript has opened at its end.
        guard let contentHeight else { return false }
        if isPinned, edge.contentHeight > contentHeight {
            return true
        }
        isPinned = edge.isAtBottom
        return false
    }

    mutating func pin() {
        isPinned = true
    }
}

/// Holds the pin state where SwiftUI does not watch it. The content height moves on every streamed flush, and only a
/// change of `isPinned`, which the view copies into its own state, is worth redrawing the transcript for.
private final class ChatScrollTracker {
    var pinning = ChatScrollPinning()
}

/// A control floating over the transcript, so it has to read over code and tables as well as over prose. macOS 26
/// draws such a control in glass; before that a bordered button carries its own opaque fill, round from macOS 14.
private struct FloatingButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
        } else if #available(macOS 14, *) {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// The scroll anchor opens the transcript at its end and keeps it there as content grows, leaving a reader who
/// scrolled up where they are. macOS 15 applies it to those two roles alone, so a short conversation still starts at
/// the top; macOS 14 has one anchor for every role. macOS 13 has none, so the transcript opens at the end once and
/// follows growth through `ChatScrollPinning`.
private struct FollowsGrowthAtBottom: ViewModifier {
    let scrollToBottom: () -> Void

    @State private var hasScrolled = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else if #available(macOS 14, *) {
            content.defaultScrollAnchor(.bottom)
        } else {
            /// Re-adding the pane fires `onAppear` again while the scroll view keeps its offset, so it scrolls on the
            /// first appearance only, or a reader who had scrolled up is thrown back to the end.
            content.onAppear {
                guard !hasScrolled else { return }
                hasScrolled = true
                scrollToBottom()
            }
        }
    }
}
