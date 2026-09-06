//
//  AssistantState.swift
//  TablePro
//

import Foundation

/// The assistant surface's own state.
///
/// The view model is built by `activate()` and by nothing else. It used to be a lazily-created
/// property whose laziness was defeated one line into the window's `onAppear`, which read it to
/// hand the coordinator a weak reference; `AIChatViewModel.init` loads the stored conversations, so
/// every connection window read the whole chat history off disk on the window-open path, with the
/// assistant never revealed and with the feature turned off in settings. Activation is now the
/// single door, and only revealing the surface or invoking an assistant command opens it.
@MainActor @Observable internal final class AssistantState {
    internal var context: AssistantContext = .empty

    @ObservationIgnored private var activatedViewModel: AIChatViewModel?

    /// Observable, unlike the view model itself, so the window can seed the assistant's context the
    /// moment it comes into existence. The last context update ran before it did and skipped it.
    internal private(set) var isActivated = false

    /// Nil until something actually needs the assistant. Readers that only want to talk to a live
    /// assistant take this and do nothing when it is nil, rather than bringing one into existence.
    internal var viewModelIfActivated: AIChatViewModel? { activatedViewModel }

    /// Builds the view model on first call and returns the same one afterwards.
    @discardableResult
    internal func activate() -> AIChatViewModel {
        if let activatedViewModel { return activatedViewModel }
        let viewModel = AIChatViewModel()
        activatedViewModel = viewModel
        isActivated = true
        return viewModel
    }

    internal func teardown() {
        activatedViewModel?.clearSessionData()
        context = .empty
    }
}
