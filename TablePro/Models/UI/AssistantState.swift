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
///
/// When a connection is supplied, the view model comes from `AgentSessionRegistry` so the trailing
/// pane and Assistant mode share one session. A connection-less activate is the test path, and
/// builds a throwaway view model that never enters the registry.
@MainActor @Observable internal final class AssistantState {
    internal var context: AssistantContext = .empty

    @ObservationIgnored private var activatedViewModel: AIChatViewModel?
    @ObservationIgnored private let connectionId: UUID?
    @ObservationIgnored private let registry: AgentSessionRegistry

    /// Observable, unlike the view model itself, so the window can seed the assistant's context the
    /// moment it comes into existence. The last context update ran before it did and skipped it.
    internal private(set) var isActivated = false

    /// Nil until something actually needs the assistant. Readers that only want to talk to a live
    /// assistant take this and do nothing when it is nil, rather than bringing one into existence.
    internal var viewModelIfActivated: AIChatViewModel? { activatedViewModel }

    internal init(
        connectionId: UUID? = nil,
        registry: AgentSessionRegistry = .shared
    ) {
        self.connectionId = connectionId
        self.registry = registry
    }

    /// Builds the view model on first call and returns the same one afterwards.
    @discardableResult
    internal func activate(connection: DatabaseConnection? = nil) -> AIChatViewModel {
        if let activatedViewModel { return activatedViewModel }
        let viewModel: AIChatViewModel
        if let connection {
            viewModel = registry.session(for: connection).viewModel
        } else {
            viewModel = AIChatViewModel()
        }
        activatedViewModel = viewModel
        isActivated = true
        return viewModel
    }

    /// The session is stopped, not cleared. `clearSessionData()` emptied `messages` on a path the
    /// user never asked to lose a transcript on. A connection-less activate still clears, because
    /// that view model never entered the registry.
    internal func teardown() {
        if let connectionId {
            registry.stopSessions(for: connectionId)
        } else {
            activatedViewModel?.discardUnregisteredSession()
        }
        activatedViewModel = nil
        isActivated = false
        context = .empty
    }
}
