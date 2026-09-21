//
//  TrailingPaneCommandTitleTests.swift
//  TableProTests
//
//  The View menu's two trailing-pane commands take their titles, their effects and their enablement
//  from the surface the pane is drawing. They used to read the stored surface with no content-mode
//  term, so in Agent mode Show Inspector read Hide Inspector over the result column and closed it
//  with nothing able to bring it back, and Show Assistant wrote a browse preference and changed
//  nothing on screen.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Trailing pane command titles")
struct TrailingPaneCommandTitleTests {
    private struct Row {
        let mode: ConnectionWorkspaceContentMode
        let stored: TrailingPaneSurface
        let isOpen: Bool
        let isAIEnabled: Bool
        let paneTitle: String
        let assistantTitle: String

        var context: TrailingPaneCommandResolver.Context {
            TrailingPaneCommandResolver.Context(
                contentMode: mode,
                storedSurface: stored,
                isPaneOpen: isOpen,
                isAIEnabled: isAIEnabled,
                hasContent: true
            )
        }

        var label: String {
            "\(mode) stored=\(stored) open=\(isOpen) ai=\(isAIEnabled)"
        }
    }

    private static let showInspector = String(localized: "Show Inspector")
    private static let hideInspector = String(localized: "Hide Inspector")
    private static let showAssistant = String(localized: "Show Assistant")
    private static let hideAssistant = String(localized: "Hide Assistant")
    private static let showResult = String(localized: "Show Result")
    private static let hideResult = String(localized: "Hide Result")

    /// Every combination of mode, stored surface, pane state and AI setting, written out rather than
    /// derived, so the table is the specification and not a second copy of the resolver.
    ///
    /// Agent mode with the AI setting off is browsing, and the stored `.agentResult` a browse window
    /// can hold in memory resolves to the inspector, so those rows read like the inspector's.
    private static let rows: [Row] = [
        Row(mode: .browse, stored: .inspector, isOpen: true, isAIEnabled: true,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .inspector, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .inspector, isOpen: false, isAIEnabled: true,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .inspector, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .assistant, isOpen: true, isAIEnabled: true,
            paneTitle: showInspector, assistantTitle: hideAssistant),
        Row(mode: .browse, stored: .assistant, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .assistant, isOpen: false, isAIEnabled: true,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .assistant, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .agentResult, isOpen: true, isAIEnabled: true,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .agentResult, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .agentResult, isOpen: false, isAIEnabled: true,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .browse, stored: .agentResult, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .inspector, isOpen: true, isAIEnabled: true,
            paneTitle: hideResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .inspector, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .inspector, isOpen: false, isAIEnabled: true,
            paneTitle: showResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .inspector, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .assistant, isOpen: true, isAIEnabled: true,
            paneTitle: hideResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .assistant, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .assistant, isOpen: false, isAIEnabled: true,
            paneTitle: showResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .assistant, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .agentResult, isOpen: true, isAIEnabled: true,
            paneTitle: hideResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .agentResult, isOpen: true, isAIEnabled: false,
            paneTitle: hideInspector, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .agentResult, isOpen: false, isAIEnabled: true,
            paneTitle: showResult, assistantTitle: showAssistant),
        Row(mode: .agent, stored: .agentResult, isOpen: false, isAIEnabled: false,
            paneTitle: showInspector, assistantTitle: showAssistant),
    ]

    @Test("The table covers every combination once")
    func tableIsComplete() {
        let labels = Set(Self.rows.map(\.label))
        #expect(labels.count == Self.rows.count)
        #expect(Self.rows.count == ConnectionWorkspaceContentMode.allCases.count
            * TrailingPaneSurface.allCases.count * 2 * 2)
    }

    @Test("View > Show Inspector names the column the pane toggle acts on")
    func paneToggleTitle() {
        for row in Self.rows {
            #expect(TrailingPaneCommandResolver.paneToggleTitle(row.context) == row.paneTitle, "\(row.label)")
        }
    }

    @Test("View > Show Assistant offers to hide only an assistant that is on screen")
    func assistantToggleTitle() {
        for row in Self.rows {
            #expect(
                TrailingPaneCommandResolver.assistantToggleTitle(row.context) == row.assistantTitle,
                "\(row.label)"
            )
        }
    }

    /// A title that says Hide has to hide, and one that says Show has to open the pane on the
    /// surface it names, or the menu promises one thing and does another.
    @Test("Each title matches what the command then does")
    func titlesMatchTheirEffects() {
        for row in Self.rows {
            let effect = TrailingPaneCommandResolver.paneToggle(row.context)
            let hides = row.paneTitle == Self.hideInspector || row.paneTitle == Self.hideResult
            #expect((effect == .hide) == hides, "\(row.label)")
            if row.paneTitle == Self.showResult {
                #expect(effect == .reveal(.agentResult), "\(row.label)")
            }
            if row.paneTitle == Self.showInspector {
                #expect(effect == .reveal(.inspector), "\(row.label)")
            }

            let assistant = TrailingPaneCommandResolver.assistantToggle(row.context)
            if row.assistantTitle == Self.hideAssistant {
                #expect(assistant == .hide, "\(row.label)")
            } else {
                #expect(assistant != .hide, "\(row.label)")
            }
        }
    }

    // MARK: - Agent mode

    /// The pane toggle opens and closes the result column, and nothing it can do lands on the
    /// inspector: the mode imposes the result, so a reveal of anything else opens on the result
    /// anyway after writing a preference the user did not choose.
    @Test("In Agent mode the pane toggle opens and closes the result column")
    func agentModePaneToggleIsTheResultColumn() {
        for stored in TrailingPaneSurface.allCases {
            let closed = Self.context(mode: .agent, stored: stored, isOpen: false)
            let open = Self.context(mode: .agent, stored: stored, isOpen: true)
            #expect(TrailingPaneCommandResolver.paneToggle(closed) == .reveal(.agentResult), "\(stored)")
            #expect(TrailingPaneCommandResolver.paneToggle(open) == .hide, "\(stored)")
            #expect(TrailingPaneCommandResolver.canTogglePane(closed), "\(stored)")
        }
    }

    /// Dimmed rather than repurposed. The conversation is the content column in Agent mode, which no
    /// command hides, and the pane holds the result, so there is no assistant to show or hide.
    @Test("In Agent mode Show Assistant is dimmed and does nothing")
    func agentModeDimsTheAssistantToggle() {
        for stored in TrailingPaneSurface.allCases {
            for isOpen in [true, false] {
                let context = Self.context(mode: .agent, stored: stored, isOpen: isOpen)
                #expect(TrailingPaneCommandResolver.assistantToggle(context) == nil, "\(stored) open=\(isOpen)")
                #expect(!TrailingPaneCommandResolver.canToggleAssistant(context), "\(stored) open=\(isOpen)")
            }
        }
    }

    /// Focus Assistant is how the keyboard reaches the conversation in Agent mode, which is the
    /// other half of dimming Show Assistant there.
    @Test("In Agent mode Focus Assistant goes to the conversation and Focus Inspector is dimmed")
    func agentModeFocusTargets() {
        let context = Self.context(mode: .agent, stored: .assistant, isOpen: true)
        #expect(TrailingPaneCommandResolver.assistantFocus(context) == .conversation)
        #expect(TrailingPaneCommandResolver.inspectorFocus(context) == nil)
    }

    // MARK: - Browsing

    @Test("While browsing, each focus command reveals its own surface")
    func browseFocusTargets() {
        let context = Self.context(mode: .browse, stored: .inspector, isOpen: false)
        #expect(TrailingPaneCommandResolver.inspectorFocus(context) == .trailingPane(.inspector))
        #expect(TrailingPaneCommandResolver.assistantFocus(context) == .trailingPane(.assistant))
    }

    /// Pressing the command for the surface that is not showing swaps to it rather than closing the
    /// pane, which is what makes two commands over one pane read like two commands over two panes.
    @Test("Show Inspector over an open assistant swaps rather than closes")
    func inspectorOverAssistantSwaps() {
        let context = Self.context(mode: .browse, stored: .assistant, isOpen: true)
        #expect(TrailingPaneCommandResolver.paneToggle(context) == .reveal(.inspector))
        #expect(TrailingPaneCommandResolver.assistantToggle(context) == .hide)
    }

    @Test("Show Assistant over an open inspector swaps rather than closes")
    func assistantOverInspectorSwaps() {
        let context = Self.context(mode: .browse, stored: .inspector, isOpen: true)
        #expect(TrailingPaneCommandResolver.assistantToggle(context) == .reveal(.assistant))
        #expect(TrailingPaneCommandResolver.paneToggle(context) == .hide)
    }

    /// The assistant is the one surface a setting takes away, so its command goes with it.
    @Test("With AI off Show Assistant is dimmed")
    func aiOffDimsTheAssistant() {
        let context = Self.context(mode: .browse, stored: .assistant, isOpen: false, isAIEnabled: false)
        #expect(TrailingPaneCommandResolver.assistantToggle(context) == nil)
        #expect(TrailingPaneCommandResolver.assistantFocus(context) == nil)
    }

    /// Opening needs a session to put in the pane; closing one the user left open does not, or a
    /// dropped connection strands an empty column.
    @Test("Without content the pane can be closed but not opened")
    func withoutContentThePaneOnlyCloses() {
        let open = Self.context(mode: .browse, stored: .inspector, isOpen: true, hasContent: false)
        let closed = Self.context(mode: .browse, stored: .inspector, isOpen: false, hasContent: false)
        #expect(TrailingPaneCommandResolver.canTogglePane(open))
        #expect(!TrailingPaneCommandResolver.canTogglePane(closed))

        let assistantOpen = Self.context(mode: .browse, stored: .assistant, isOpen: true, hasContent: false)
        let assistantClosed = Self.context(mode: .browse, stored: .assistant, isOpen: false, hasContent: false)
        #expect(TrailingPaneCommandResolver.assistantToggle(assistantOpen) == .hide)
        #expect(TrailingPaneCommandResolver.assistantToggle(assistantClosed) == nil)
    }

    /// A dead fourth name for the pane toggle, beside Inspector in the menu, trailing pane in the
    /// proxy and right panel in a legacy defaults key. Nothing called it, and a command surface that
    /// keeps a name nobody uses is where the next caller picks the wrong one.
    @Test("The command surface has no second name for the pane toggle")
    func toggleRightSidebarIsGone() throws {
        let url = Self.repositoryRoot.appendingPathComponent("TablePro/Views/Main/MainContentCommandActions.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("toggleRightSidebar"))
    }

    // MARK: - Helpers

    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    private static func context(
        mode: ConnectionWorkspaceContentMode,
        stored: TrailingPaneSurface,
        isOpen: Bool,
        isAIEnabled: Bool = true,
        hasContent: Bool = true
    ) -> TrailingPaneCommandResolver.Context {
        TrailingPaneCommandResolver.Context(
            contentMode: mode,
            storedSurface: stored,
            isPaneOpen: isOpen,
            isAIEnabled: isAIEnabled,
            hasContent: hasContent
        )
    }
}
