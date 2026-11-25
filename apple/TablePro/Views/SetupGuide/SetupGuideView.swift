import SwiftUI

internal enum SetupGuideImportSheet: Identifiable {
    case notice(KeychainNotice)
    case review(ForeignAppRead, UUID)

    var id: String {
        switch self {
        case .notice(let notice): "notice-\(notice.id)"
        case .review(_, let id): "review-\(id.uuidString)"
        }
    }

    init?(step: SetupGuideStep, phase: SetupGuideImportPhase) {
        guard step == .import else { return nil }
        switch phase {
        case .notice(let notice): self = .notice(notice)
        case .review(let read, let id): self = .review(read, id)
        case .scanning, .choosing, .pickingFile, .reading: return nil
        }
    }
}

// Buttons sit in a footer inside the content: a toolbar would bridge into the title bar.
internal struct SetupGuideView: View {
    @ObservedObject var model: SetupGuideModel

    @AccessibilityFocusState private var headingFocused: Bool
    @State private var shownStep: SetupGuideStep
    @State private var movesForward = true
    @State private var presentedSheetId: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SetupGuideModel) {
        self.model = model
        _shownStep = State(initialValue: model.step)
    }

    var body: some View {
        // The footer sits below the scroll view, not in a safe area bar over it: the scroll view under a bar answers the bar's accessibility hit tests.
        VStack(spacing: 0) {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        SetupGuideHero(step: shownStep, headingFocused: $headingFocused)
                        stepContent
                    }
                    .padding(.horizontal, 40)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560 + 80)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBasedOnSize()
                .id(shownStep)
                .transition(stepTransition)
            }
            .modifier(TitlebarClip())
            SetupGuideFooter(model: model)
                .modifier(FooterBackground())
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 560, idealHeight: 660)
        .sheet(item: importSheet) { sheet in
            sheetContent(sheet)
                .onAppear { presentedSheetId = sheet.id }
        }
        .onValueChange(of: model.step) { old, new in
            stepDidChange(from: old, to: new)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch shownStep {
        case .origin:
            SetupGuideOriginStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-origin")
        case .import:
            SetupGuideImportStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-import")
        case .firstConnection:
            SetupGuideFirstConnectionStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-first-connection")
        case .options:
            SetupGuideOptionsStep(model: model)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("setup-guide-step-options")
        }
    }

    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let offset: CGFloat = movesForward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: offset).combined(with: .opacity),
            removal: .offset(x: -offset).combined(with: .opacity)
        )
    }

    // Reduce Motion keeps a short fade, which withMotion would drop along with the slide.
    private var stepAnimation: Animation {
        if reduceMotion {
            return .easeInOut(duration: 0.15)
        }
        if #available(macOS 14.0, *) {
            return .smooth(duration: 0.28)
        }
        return .easeInOut(duration: 0.25)
    }

    // The outgoing step leaves with the transition it last rendered, so the direction lands one turn before the step.
    private func stepDidChange(from old: SetupGuideStep, to new: SetupGuideStep) {
        movesForward = SetupGuideHero.index(of: new) > SetupGuideHero.index(of: old)
        Task { @MainActor in
            withTransaction(Transaction(animation: stepAnimation)) {
                shownStep = model.step
            }
            headingFocused = true
            if #unavailable(macOS 14) {
                AccessibilityAnnouncement.post(SetupGuideHero.announcement(of: model.step))
            }
        }
    }

    private var importSheet: Binding<SetupGuideImportSheet?> {
        Binding(
            get: { SetupGuideImportSheet(step: model.step, phase: model.importPhase) },
            set: { sheet in
                guard sheet == nil else { return }
                // A dismissal the sheet's own buttons did not make still moves the queue on, once.
                let current = SetupGuideImportSheet(step: model.step, phase: model.importPhase)
                guard let current, current.id == presentedSheetId else { return }
                presentedSheetId = nil
                model.skipCurrentSource()
            }
        )
    }

    @ViewBuilder
    private func sheetContent(_ sheet: SetupGuideImportSheet) -> some View {
        switch sheet {
        case .notice(let notice):
            KeychainNoticeView(
                notice: notice,
                onContinue: { model.confirmKeychainNotice() },
                onCancel: { model.skipCurrentSource() }
            )
            .frame(width: 480)
        case .review(let read, let id):
            ImportReviewStep(
                title: read.title,
                banner: read.banner,
                preview: read.preview,
                onBack: nil,
                onCancel: { model.skipCurrentSource() },
                onFinished: { model.reviewFinished($0) }
            )
            .importSheetFrame()
            .id(id)
        }
    }
}

// Before macOS 26 nothing fades content under the transparent title bar, so the scroll view stops below it.
private struct TitlebarClip: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.clipped()
        }
    }
}

// macOS 26 puts its glass buttons straight on the window; earlier versions mark the bar with its material.
private struct FooterBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content.background(.bar)
        }
    }
}
