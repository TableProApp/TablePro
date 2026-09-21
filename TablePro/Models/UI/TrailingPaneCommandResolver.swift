//
//  TrailingPaneCommandResolver.swift
//  TablePro
//

import Foundation

/// What the window's trailing-pane commands say, do and allow, decided from the surface the pane is
/// actually drawing.
///
/// The commands used to read the stored surface with no content-mode term. In Agent mode, where the
/// pane draws the session's result whatever was stored, Show Inspector titled itself Hide Inspector
/// over the result column and collapsed it with no command able to bring it back, and Show Assistant
/// wrote the assistant into the connection's browse preference and changed nothing on screen. Every
/// answer here goes through `TrailingPaneSurfaceResolver` instead, and the View menu, the toolbar and
/// the focus commands all read the same value.
internal enum TrailingPaneCommandResolver {
    /// Everything the commands decide from, read once per question.
    internal struct Context: Equatable {
        internal let contentMode: ConnectionWorkspaceContentMode
        internal let storedSurface: TrailingPaneSurface
        internal let isPaneOpen: Bool
        internal let isAIEnabled: Bool
        /// Whether the window has a connection's content behind it. Opening a surface needs one;
        /// closing a pane the user left open does not, or a connection that drops with the pane open
        /// leaves an empty column with no command to close it.
        internal let hasContent: Bool

        internal init(
            contentMode: ConnectionWorkspaceContentMode,
            storedSurface: TrailingPaneSurface,
            isPaneOpen: Bool,
            isAIEnabled: Bool,
            hasContent: Bool
        ) {
            self.contentMode = contentMode
            self.storedSurface = storedSurface
            self.isPaneOpen = isPaneOpen
            self.isAIEnabled = isAIEnabled
            self.hasContent = hasContent
        }

        /// The mode the window draws, which is browsing whenever the AI feature is off.
        internal var resolvedMode: ConnectionWorkspaceContentMode {
            ConnectionWorkspaceContentMode.resolved(contentMode, isAIEnabled: isAIEnabled)
        }

        internal var drawnSurface: TrailingPaneSurface {
            TrailingPaneSurfaceResolver.resolve(
                stored: storedSurface,
                contentMode: contentMode,
                isAIEnabled: isAIEnabled
            )
        }

        /// A collapsed pane shows nothing, whatever it would draw once revealed.
        internal func isShowing(_ surface: TrailingPaneSurface) -> Bool {
            isPaneOpen && drawnSurface == surface
        }
    }

    internal enum Effect: Equatable {
        /// Put the pane on screen, drawing this surface.
        case reveal(TrailingPaneSurface)
        case hide
    }

    /// What asking for a surface does to the pane and to the connection's stored preference.
    internal struct Reveal: Equatable {
        internal let opensPane: Bool
        internal let storesChoice: Bool
    }

    /// Where a focus command sends the keyboard.
    internal enum FocusTarget: Equatable {
        /// The trailing pane, revealed on this surface first.
        case trailingPane(TrailingPaneSurface)
        /// The window's content column, which is where Agent mode draws the conversation.
        case conversation
    }

    // MARK: - Asking for a Surface

    /// The pane opens only on a surface the mode and the settings let it draw, or it would open on
    /// something the user did not ask for: the assistant's commands reach the window from Agent mode,
    /// where the conversation they seed is the content column and the pane beside it is the result.
    ///
    /// Only a choice is stored: a surface the user may pick, asked for while browsing. Agent mode
    /// imposes the result and the next read overrides whatever is stored, so a write there changed
    /// the connection's browse preference and nothing on screen.
    internal static func reveal(_ surface: TrailingPaneSurface, _ context: Context) -> Reveal {
        let isDrawn = TrailingPaneSurfaceResolver.draws(
            surface,
            contentMode: context.contentMode,
            isAIEnabled: context.isAIEnabled
        )
        return Reveal(
            opensPane: isDrawn,
            storesChoice: isDrawn && surface.isUserSelectable && context.resolvedMode == .browse
        )
    }

    /// Whether a grid click with auto-show on opens the pane. It never stores anything: a click is
    /// a suggestion, and Xcode's line between the two applies, where a surface the user picked is
    /// remembered and one the app offered is not.
    ///
    /// It reads the stored surface rather than whether the assistant is on screen, which is false
    /// whenever the pane is collapsed. The first click after closing a pane left on the assistant
    /// used to open it on the inspector and persist the inspector over the user's choice.
    internal static func revealsForSelection(_ context: Context) -> Bool {
        context.drawnSurface == .inspector && !context.isPaneOpen
    }

    // MARK: - The Pane Toggle

    /// ⌥⌘I, View > Show Inspector and the toolbar's trailing item all send `toggleInspector:`, and
    /// that item is AppKit's own, so this is the window's one trailing-pane toggle rather than the
    /// inspector's alone. In Agent mode the column it opens and closes is the result, and the title
    /// names that column rather than one the window is not drawing.
    internal static func paneToggleTitle(_ context: Context) -> String {
        switch context.resolvedMode {
        case .agent:
            return context.isPaneOpen ? String(localized: "Hide Result") : String(localized: "Show Result")
        case .browse:
            return context.isShowing(.inspector)
                ? String(localized: "Hide Inspector")
                : String(localized: "Show Inspector")
        }
    }

    /// Over the other surface it swaps rather than closes, which is what makes two commands over one
    /// pane read the way two commands over two panes would.
    internal static func paneToggle(_ context: Context) -> Effect {
        switch context.resolvedMode {
        case .agent:
            return context.isPaneOpen ? .hide : .reveal(.agentResult)
        case .browse:
            return context.isShowing(.inspector) ? .hide : .reveal(.inspector)
        }
    }

    internal static func canTogglePane(_ context: Context) -> Bool {
        context.hasContent || context.isPaneOpen
    }

    // MARK: - The Assistant

    internal static func assistantToggleTitle(_ context: Context) -> String {
        context.isShowing(.assistant) ? String(localized: "Hide Assistant") : String(localized: "Show Assistant")
    }

    /// Nil where the command does not apply, and Agent mode is one of those places: it is dimmed
    /// there rather than turned into something else. The mode draws the conversation as the window's
    /// content column, which no command hides, and imposes the result on the pane, so there is no
    /// assistant surface to show or to hide. Focusing the conversation instead would give one chord two
    /// unrelated meanings that one title cannot describe, and Focus Assistant already reaches it.
    internal static func assistantToggle(_ context: Context) -> Effect? {
        guard context.resolvedMode == .browse else { return nil }
        if context.isShowing(.assistant) { return .hide }
        guard context.isAIEnabled, context.hasContent else { return nil }
        return .reveal(.assistant)
    }

    internal static func canToggleAssistant(_ context: Context) -> Bool {
        assistantToggle(context) != nil
    }

    // MARK: - Focus

    /// Agent mode draws no inspector, so the command has nothing to focus there. Revealing one would
    /// have meant writing a browse preference the mode overrides on the next read.
    internal static func inspectorFocus(_ context: Context) -> FocusTarget? {
        guard context.resolvedMode == .browse, canTogglePane(context) else { return nil }
        return .trailingPane(.inspector)
    }

    /// The assistant is one conversation shown two ways, so its focus command follows it: into the
    /// trailing pane while browsing, and into the content column in Agent mode.
    internal static func assistantFocus(_ context: Context) -> FocusTarget? {
        switch context.resolvedMode {
        case .agent:
            return .conversation
        case .browse:
            return canToggleAssistant(context) ? .trailingPane(.assistant) : nil
        }
    }
}
