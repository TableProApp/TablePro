//
//  AIChatCodeThemeTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
@testable import TablePro
import Testing

@MainActor
struct AIChatCodeThemeTests {
    private static let json = "{\n  \"database\" : \"app\",\n  \"query\" : \"select * from users\"\n}"

    private static let statement = ProposedStatement(
        id: "1",
        sql: "update users set active = 0 where id = 7",
        toolName: "execute_sql",
        state: .waiting
    )

    /// The row as it was drawn before the theme reached it.
    private static func systemRow(_ statement: ProposedStatement) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(statement.sql)
                .font(ThemeEngine.shared.valueFontSwiftUI)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 4) {
                Image(systemName: statement.state.symbolName)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(statement.state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @Test("The tool-use input and tool-result wells keep the font they drew before", arguments: [ColorScheme.light, .dark])
    func toolWellFontsMatchTheirFormerText(colorScheme: ColorScheme) throws {
        let former = try ThemeTestFixture.bitmap(
            of: Text(Self.json).font(.caption).fontDesign(.monospaced),
            colorScheme: colorScheme
        )
        let input = try ThemeTestFixture.bitmap(
            of: Text(Self.json).font(AIChatToolUseBlockView.inputFont),
            colorScheme: colorScheme
        )
        let result = try ThemeTestFixture.bitmap(
            of: Text(Self.json).font(AIChatToolResultBlockView.contentFont),
            colorScheme: colorScheme
        )

        #expect(ThemeTestFixture.sameBytes(former, input))
        #expect(ThemeTestFixture.sameBytes(former, result))
    }

    @Test("Under the default pair a proposed statement draws exactly what it drew before", arguments: [ColorScheme.light, .dark])
    func proposedStatementIsNativeUnderTheDefaultPair(colorScheme: ColorScheme) throws {
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let themed = try ThemeTestFixture.bitmap(
                of: AgentProposedStatementRow(statement: Self.statement).frame(width: 320),
                colorScheme: colorScheme
            )
            let system = try ThemeTestFixture.bitmap(
                of: Self.systemRow(Self.statement).frame(width: 320),
                colorScheme: colorScheme
            )
            #expect(ThemeTestFixture.sameBytes(themed, system))
        }
    }

    @Test("A proposed statement wears the editor's text while the theme sets it")
    func proposedStatementFollowsTheEditorText() throws {
        let pair = try ThemeTestFixture.pair([.editorText: "#FF00FF"])
        try ThemeTestFixture.adopting(pair, appearance: .dark) {
            let row = try ThemeTestFixture.bitmap(of: AgentProposedStatementRow(statement: Self.statement).frame(width: 320), colorScheme: .dark)
            #expect(ThemeTestFixture.count(in: row, where: ThemeTestFixture.isMagenta) > 0)
        }
        try ThemeTestFixture.adopting(.builtIn, appearance: .dark) {
            let row = try ThemeTestFixture.bitmap(of: AgentProposedStatementRow(statement: Self.statement).frame(width: 320), colorScheme: .dark)
            #expect(ThemeTestFixture.count(in: row, where: ThemeTestFixture.isMagenta) == 0)
        }
    }
}
