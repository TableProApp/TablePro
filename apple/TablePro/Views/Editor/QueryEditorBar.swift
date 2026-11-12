//
//  QueryEditorBar.swift
//  TablePro
//

import AppKit
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
///
/// Settings > Editor can put it on two rows (`EditorSettings.queryBarTwoRows`), which adds Save, the
/// Query Builder, Snippets and the tab's connection. `QueryEditorBarLayout` decides which control sits
/// on which row; off, it is the single row above. The first of the two rows is a run of borderless
/// glyphs at the toolbar's size rather than small bezels, because it sits right under the toolbar and
/// small grey bezels there read as disabled even when they are not.
struct QueryEditorBar: View {
    /// The glyph size of the first row's tools, the regular size the window's toolbar draws at.
    static let toolGlyphSize: CGFloat = 15
    /// Each tool's target, wider than its glyph so the run is easy to hit and reads as separate tools.
    static let toolTargetSize = CGSize(width: 26, height: 22)
    /// The first row holds glyphs with no bezel, so they need more air between them than the second.
    static let toolSpacing: CGFloat = 10

    let scope: QueryScopeBarModel
    let commands: QueryCommandAvailability
    let isExecuting: Bool
    let vimMode: VimMode?
    /// Whether the first-run tip pointing at query history is still owed. It anchors to the Run
    /// menu, which is the control that produces the history it is telling the reader about.
    let showsHistoryTip: Bool

    let onAIAction: (AIQueryAction) -> Void
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
    /// What the second row and the extra commands need. Nil draws the single row.
    var twoRow: TwoRowInput?

    /// The two-row bar's own inputs, given only while the setting is on, so the single row never
    /// reads the connection library or the saved queries.
    struct TwoRowInput {
        let connection: QueryConnectionPickerModel
        let savedQueries: ConnectionDataCache
        let onSave: () -> Void
        let onOpenQueryBuilder: () -> Void
        let onInsertSavedQuery: (SQLFavorite) -> Void
    }

    private var rows: [QueryEditorBarRow] {
        QueryEditorBarLayout.rows(
            twoRows: twoRow != nil,
            showsQueryBuilder: commands.showsQueryBuilder,
            showsAI: commands.aiActions.isVisible,
            showsVimMode: vimMode != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: row.leading.contains(.save) ? Self.toolSpacing : 8) {
                    ForEach(row.leading, id: \.self) { control($0) }

                    Spacer(minLength: 8)

                    ForEach(row.trailing, id: \.self) { control($0) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .paneBarBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("query-editor-bar")
    }

    @ViewBuilder
    private func control(_ control: QueryEditorBarControl) -> some View {
        switch control {
        case .database:
            QueryContainerPicker(
                containers: scope.containers,
                selectedName: scope.selectedName,
                entityName: scope.entityName,
                isReadOnly: scope.isReadOnly,
                schemaName: scope.schemaName,
                onChange: onContainerChanged
            )
            // A run moved to another database mid-flight would either land its rows there or lose what it committed.
            .disabled(isExecuting)
        case .vimMode:
            if let vimMode {
                VimModeIndicatorView(mode: vimMode)
            }
        case .editingCommands:
            editingCommands
        case .ai:
            if twoRow != nil {
                aiTool
            } else {
                aiControl
            }
        case .explain:
            explainControl
        case .run:
            runControl
        case .save:
            if let twoRow {
                toolButton(.save, title: String(localized: "Save"), systemImage: "square.and.arrow.down", action: twoRow.onSave)
                    .disabled(!commands.canSave)
                    .help(commands.saveHint)
                    .accessibilityIdentifier("query-save")
            }
        case .separator:
            Divider()
                .frame(height: 18)
                .accessibilityHidden(true)
        case .queryBuilder:
            if let twoRow {
                toolButton(
                    .queryBuilder,
                    title: String(localized: "Query Builder"),
                    systemImage: "hammer",
                    action: twoRow.onOpenQueryBuilder
                )
                .disabled(!commands.canOpenQueryBuilder)
                .help(commands.queryBuilderHint)
                .accessibilityIdentifier("query-builder")
            }
        case .format:
            toolButton(.format, title: String(localized: "Format"), systemImage: "wand.and.stars", action: onFormat)
                .disabled(!commands.canFormat)
                .help(commands.beautifyHint)
                .accessibilityIdentifier("query-format")
        case .snippets:
            if let twoRow {
                QuerySnippetsMenu(
                    savedQueries: twoRow.savedQueries,
                    canSaveCurrentQuery: commands.canSaveAsFavorite,
                    onInsert: twoRow.onInsertSavedQuery,
                    onSaveCurrentQuery: onSaveAsFavorite
                )
            }
        case .connection:
            if let twoRow {
                QueryConnectionPicker(model: twoRow.connection)
            }
        }
    }

    /// The two-row bar's editing tools stand alone rather than in a `ControlGroup`, because a separator
    /// sits between them and Save. Borderless at the toolbar's size, so the row reads as the toolbar's
    /// continuation. The name is set on the button itself: the glyph is all that draws, and an image
    /// carries no name of its own to VoiceOver.
    private func toolButton(
        _ control: QueryEditorBarControl,
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                QueryBarToolGlyph(control: control, systemImage: systemImage, title: title)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .accessibilityLabel(title)
    }

    /// The single row's AI control as a first-row tool: Review on a click, the other actions in its menu.
    /// One control rather than a group, because a group draws a bezel and both halves share one state.
    /// `.accessibilityLabel` names a `Menu` only beside `.accessibilityElement(children: .contain)`.
    private var aiTool: some View {
        Menu {
            ForEach(AIQueryAction.editorActions, id: \.self) { action in
                Button(action.menuTitle, systemImage: action.systemImage) { onAIAction(action) }
            }
        } label: {
            Label {
                Text(AIQueryAction.review.menuTitle)
            } icon: {
                QueryBarToolGlyph(control: .ai, systemImage: "sparkles", title: AIQueryAction.review.menuTitle)
            }
        } primaryAction: {
            onAIAction(.review)
        }
        .labelStyle(.iconOnly)
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.visible)
        .controlSize(.regular)
        .fixedSize()
        .disabled(!commands.aiActions.isEnabled)
        .help(commands.aiReviewHint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AIQueryAction.review.menuTitle)
        .accessibilityIdentifier("query-ai-review")
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

    private var aiControl: some View {
        ControlGroup {
            Button(String(localized: "Review"), systemImage: "sparkles") { onAIAction(.review) }
                .labelStyle(.titleAndIcon)
                .help(commands.aiReviewHint)
                .accessibilityLabel(AIQueryAction.review.menuTitle)
                .accessibilityIdentifier("query-ai-review")

            Menu {
                ForEach(AIQueryAction.editorActions, id: \.self) { action in
                    Button(action.menuTitle, systemImage: action.systemImage) { onAIAction(action) }
                }
            } label: {
                Label { Text("AI Actions") } icon: { EmptyView() }
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.visible)
            .help(String(localized: "AI Actions"))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "AI Actions"))
            .accessibilityIdentifier("query-ai-menu")
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(!commands.aiActions.isEnabled)
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
    ///
    /// The menu half draws nothing but the segment's own disclosure chevron. A visible label of any
    /// kind lands beside that chevron rather than replacing it: `systemImage:` puts a second one
    /// there, and a bare `Text` survives `.labelStyle(.iconOnly)` and widens the segment from 47pt
    /// to 115pt. A `Label` whose icon is empty is the one shape that renders as the chevron alone
    /// and still carries a name: measured, the menu half publishes "Run Options" as its
    /// accessibility label. `.accessibilityLabel` on a `Menu` names it only beside
    /// `.accessibilityElement(children: .contain)`, as the AI menu has; on its own it replaces the
    /// label's name with nothing at all.
    @ViewBuilder
    private var runControl: some View {
        if isExecuting {
            Button(String(localized: "Stop"), systemImage: "stop.fill", action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .labelStyle(.titleAndIcon)
                .disabled(!commands.canStop)
                .help(commands.stopHint)
                .accessibilityIdentifier("query-stop")
        } else {
            ControlGroup {
                Button(String(localized: "Run"), systemImage: "play.fill", action: onRun)
                    .labelStyle(.titleAndIcon)
                    .disabled(!commands.canRun)
                    .help(commands.runHint)
                    .accessibilityIdentifier("query-run")

                Menu {
                    Button(String(localized: "Run All Statements"), action: onRunAllStatements)
                        .disabled(!commands.canRun)
                    Button(String(localized: "Run Without Limit"), action: onRunWithoutLimit)
                        .disabled(!commands.canRun)
                    Divider()
                    Button(String(localized: "Clear Query"), action: onClearQuery)
                        .disabled(!commands.canClearQuery)
                    Button(String(localized: "Clear Results"), action: onClearResults)
                        .disabled(!commands.canClearResults)
                } label: {
                    Label { Text("Run Options") } icon: { EmptyView() }
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.visible)
                .disabled(!commands.canOpenRunMenu)
                .help(String(localized: "Run Options"))
                .accessibilityIdentifier("query-run-menu")
                .historyTipAnchor(isEnabled: showsHistoryTip)
            }
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// A first-row tool's glyph. In the colorful icon style it wears its tool's hue while the tool can act,
/// drawn as the toolbar draws its Objects buttons: a hierarchical symbol baked into a non-template image,
/// because a menu's button draws a template symbol in its text color. Disabled, it is the plain template
/// glyph, which the control dims the way the system dims any other, so it never reads as available.
struct QueryBarToolGlyph: View {
    let control: QueryEditorBarControl
    let systemImage: String
    let title: String

    /// Observed so the hue follows the icon style while the bar is on screen.
    @ObservedObject private var settings = AppSettingsManager.shared
    @Environment(\.isEnabled) private var isEnabled

    init(control: QueryEditorBarControl, systemImage: String, title: String) {
        self.control = control
        self.systemImage = systemImage
        self.title = title
    }

    var body: some View {
        glyph
            .frame(width: QueryEditorBar.toolTargetSize.width, height: QueryEditorBar.toolTargetSize.height)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var glyph: some View {
        if isEnabled,
           let tint = QueryEditorBarToolTint.tint(for: control, style: settings.appearance.objectIconStyle),
           let image = Self.tintedImage(systemImage, tint: tint.nsColor, title: title) {
            Image(nsImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: QueryEditorBar.toolGlyphSize))
        }
    }

    static func tintedImage(_ symbol: String, tint: NSColor, title: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: QueryEditorBar.toolGlyphSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: tint))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}
