//
//  TrailingPaneHeaderModel.swift
//  TablePro
//

import Foundation

/// The groups of commands a surface's header menu carries, in the order they are drawn, with a
/// separator between each.
internal enum TrailingPaneMenuSection: Hashable {
    /// Fields or JSON, the two renderings of the selected row.
    case inspectorRendering
    /// Copy Visible, the two expansion commands and Always Expand Foreign Keys. They act on the JSON
    /// rendering alone, so they are offered only while it is the one on screen.
    case jsonReading
    /// New Conversation and the conversation history.
    case conversations
    /// Clear Recents, kept apart from the rest because it deletes.
    case clearRecents
    /// Which of its views the result column shows.
    case resultView
}

/// What the trailing pane's header draws above one surface.
///
/// Each surface draws the header itself, at its own top, rather than one container drawing it over
/// all three: `WorkspacePanes` parents exactly one surface's hosting controller into the split item at
/// a time, and a header outside all three would need a container controller that nothing creates. What
/// keeps the three in step is that they draw it from this one value. The hand-drawn headers it
/// replaced were a title over a subtitle beside a picker, a headline beside two 24pt buttons, and an
/// icon-only picker that was the whole top of the pane, so the pane's top edge changed shape every
/// time the surface did.
internal struct TrailingPaneHeaderModel: Equatable {
    internal let surface: TrailingPaneSurface
    internal let segments: [TrailingPaneSurface]
    internal let menuSections: [TrailingPaneMenuSection]

    /// `hasContent` is false over a connection that is not up. Every command in the menu acts on a
    /// row, a conversation or a session the window does not have then, so the menu is not drawn.
    ///
    /// `inspectorRendering` is the rendering the inspector draws when its selection can be drawn
    /// both ways, and nil when it cannot: no row, a table's info, or a schema grid's column
    /// definition, which has no JSON form. The choice is left out then rather than dimmed, because a
    /// dimmed picker still checks one of its items, and it checked the stored rendering over a pane
    /// drawing the other one or neither.
    internal init(
        surface: TrailingPaneSurface,
        contentMode: ConnectionWorkspaceContentMode,
        isAIEnabled: Bool,
        inspectorRendering: InspectorViewMode? = nil,
        hasContent: Bool = true
    ) {
        self.surface = surface
        self.segments = TrailingPaneSurfaceResolver.selectable(contentMode: contentMode, isAIEnabled: isAIEnabled)
        self.menuSections = hasContent ? Self.sections(for: surface, inspectorRendering: inspectorRendering) : []
    }

    /// A picker needs two segments, one of them the surface it sits over. Agent mode offers none and
    /// the AI setting being off leaves one, and a single segment is a control with nothing to choose,
    /// so both draw the surface's name instead.
    internal var showsPicker: Bool {
        segments.count > 1 && segments.contains(surface)
    }

    internal var title: String {
        surface.localizedTitle
    }

    /// The ellipsis carries no text, so this is both its accessibility name and its tooltip.
    internal var menuLabel: String {
        switch surface {
        case .inspector: String(localized: "Inspector Options")
        case .assistant: String(localized: "Assistant Options")
        case .agentResult: String(localized: "Result Options")
        }
    }

    private static func sections(
        for surface: TrailingPaneSurface,
        inspectorRendering: InspectorViewMode?
    ) -> [TrailingPaneMenuSection] {
        switch surface {
        case .inspector:
            switch inspectorRendering {
            case .json?: [.inspectorRendering, .jsonReading]
            case .fields?: [.inspectorRendering]
            case nil: []
            }
        case .assistant:
            [.conversations, .clearRecents]
        case .agentResult:
            [.resultView]
        }
    }
}
