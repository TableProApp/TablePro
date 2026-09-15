//
//  QueryEditorBar.swift
//  TablePro
//

import SwiftUI
import TableProPluginKit

/// The query tab's own command bar: what the editor runs against, and what it can do to the query.
///
/// It lives in the tab rather than in the window toolbar, and that is a constraint rather than a
/// preference. `NSToolbar` belongs to the window, and a window here hosts several tabs of several
/// kinds. AppKit offers no way to vary a toolbar's items per tab without rewriting its item list,
/// and `NSToolbar.itemIdentifiers` says so in the header: it "will override any customizations the
/// user has made" when `allowsUserCustomization` is on, which this app's toolbar has. It is also
/// macOS 15, above the 14.0 deployment target. Putting Run in the toolbar therefore meant five
/// permanently dimmed items on every table, structure, dashboard and diagram tab. A control that
/// belongs to the editor lives with the editor, which is what Xcode's jump bar and Script Editor's
/// navigation bar both do.
///
/// What it is not is the bar this replaced. That one opened with `Text("Query").font(.headline)`,
/// naming the pane it was already inside, and then mixed three control sizes and two button styles
/// across five controls with no grouping: borderless icon buttons for Clear, Format and Favorite, a
/// `.bordered` `.small` Explain, and a `.borderedProminent` `.small` Execute. Here every control is
/// one size, the scope leads, the commands trail, and the primary action is the only prominent one.
struct QueryEditorBar: View {
    let scope: QueryScopeBarModel
    let commands: QueryCommandAvailability
    let isExecuting: Bool
    let vimMode: VimMode?
    /// Whether the first-run tip pointing at query history is still owed. It anchors to the Run
    /// menu, which is the control that produces the history it is telling the reader about.
    let showsHistoryTip: Bool

    let onRun: () -> Void
    let onRunAllStatements: () -> Void
    let onRunWithoutLimit: () -> Void
    let onStop: () -> Void
    let onExplain: (ExplainVariant?) -> Void
    let onFormat: () -> Void
    let onSaveAsFavorite: () -> Void
    let onClearQuery: () -> Void
    let onClearResults: () -> Void
    let onContainerChanged: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            QueryContainerPicker(
                containers: scope.containers,
                selectedName: scope.selectedName,
                entityName: scope.entityName,
                isReadOnly: scope.isReadOnly,
                schemaName: scope.schemaName,
                onChange: onContainerChanged
            )

            if let vimMode {
                VimModeIndicatorView(mode: vimMode)
            }

            Spacer(minLength: 8)

            editingCommands

            explainControl

            runControl
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("query-editor-bar")
    }

    /// The two that change the query without running it, in one `ControlGroup` because adjacent
    /// related commands read as one control rather than as scattered singletons.
    private var editingCommands: some View {
        ControlGroup {
            Button(String(localized: "Format"), systemImage: "text.alignleft", action: onFormat)
                .disabled(!commands.canFormat)
                .help(commands.formatHint)

            Button(String(localized: "Save as Favorite"), systemImage: "star", action: onSaveAsFavorite)
                .disabled(!commands.canSaveAsFavorite)
                .help(commands.favoriteHint)
        }
        .labelStyle(.iconOnly)
        .controlSize(.small)
        .fixedSize()
    }

    /// A plain button when the engine has one plan to offer, and a pull-down when it has several.
    /// Both are `.bordered` `.small`, which is what every other command here is.
    @ViewBuilder
    private var explainControl: some View {
        if commands.explainVariants.count <= 1 {
            Button(String(localized: "Explain")) {
                onExplain(commands.explainVariants.first)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!commands.canExplain)
            .help(commands.explainHint)
            .accessibilityIdentifier("query-explain")
        } else {
            Menu(String(localized: "Explain")) {
                ForEach(commands.explainVariants) { variant in
                    Button(variant.label) { onExplain(variant) }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .disabled(!commands.canExplain)
            .help(commands.explainHint)
            .accessibilityIdentifier("query-explain")
        }
    }

    /// Run while idle, Stop while a query is in flight.
    ///
    /// One control rather than two side by side, because the bar is inside the pane and a second
    /// permanently dimmed button costs width the editor wants. TablePlus does the same: its Cancel
    /// appears in the query editor for a long query rather than standing there dimmed. The two are
    /// never both actionable, so nothing is reachable in one state and not the other.
    ///
    /// The two halves are separately enabled, which is the whole reason this is a `ControlGroup`
    /// and not a `Menu(primaryAction:)`. Clear Query leaves the results standing and makes Run
    /// unavailable, and disabling one control for both would have taken Clear Results down with it
    /// at exactly the moment the reader wanted it.
    @ViewBuilder
    private var runControl: some View {
        if isExecuting {
            Button(String(localized: "Stop"), systemImage: "stop.fill", action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
                .help(commands.stopHint)
                .accessibilityIdentifier("query-stop")
        } else {
            ControlGroup {
                Button(String(localized: "Run"), systemImage: "play.fill", action: onRun)
                    .labelStyle(.titleAndIcon)
                    .disabled(!commands.canRun)
                    .help(commands.runHint)
                    .accessibilityIdentifier("query-run")

                Menu(String(localized: "Run Options"), systemImage: "chevron.down") {
                    Button(String(localized: "Run All Statements"), action: onRunAllStatements)
                        .disabled(!commands.canRun)
                    Button(String(localized: "Run Without Limit"), action: onRunWithoutLimit)
                        .disabled(!commands.canRun)
                    Divider()
                    Button(String(localized: "Clear Query"), action: onClearQuery)
                        .disabled(!commands.canClearQuery)
                    Button(String(localized: "Clear Results"), action: onClearResults)
                        .disabled(!commands.canClearResults)
                }
                .labelStyle(.iconOnly)
                .disabled(!commands.canOpenRunMenu)
                .accessibilityIdentifier("query-run-menu")
                .modifier(FeatureTipPopoverAnchor(
                    tip: FindPastQueriesTip(shortcut: FeatureTipShortcut.display(for: .toggleHistory)),
                    isEnabled: showsHistoryTip
                ))
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}
