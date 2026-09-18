//
//  ClaudeAgentDisclosure.swift
//  TablePro
//

import Foundation

struct ClaudeAgentNote: Identifiable, Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        case caution
        case detail

        var symbolName: String {
            switch self {
            case .caution: return "exclamationmark.triangle.fill"
            case .detail: return "info.circle"
            }
        }
    }

    let id: String
    let severity: Severity
    let text: String
}

enum ClaudeAgentDisclosure {
    static var notes: [ClaudeAgentNote] {
        [
            ClaudeAgentNote(
                id: "unsupported-path",
                severity: .caution,
                text: String(localized: """
                TablePro runs Anthropic's claude tool in headless mode. Claude Code is built for you to use directly, \
                not as a backend for other apps, so this path can break with any Claude Code release.
                """)
            ),
            ClaudeAgentNote(
                id: "terms",
                severity: .caution,
                text: String(localized: """
                Your subscription is governed by Anthropic's Consumer Terms and Usage Policy. Read them and decide \
                whether this use fits. TablePro cannot grant rights under them.
                """)
            ),
            ClaudeAgentNote(
                id: "shared-limits",
                severity: .detail,
                text: String(localized: """
                Replies count against your Claude subscription limits. You share those limits with claude.ai and your \
                own Claude Code sessions, so running out here stops your work there too.
                """)
            ),
            ClaudeAgentNote(
                id: "data-terms",
                severity: .detail,
                text: String(localized: "Your prompts, schema, and query text reach Anthropic under your consumer plan and its privacy settings, not the API's commercial terms.")
            ),
            ClaudeAgentNote(
                id: "api-key-ignored",
                severity: .detail,
                text: String(localized: "ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN are removed from the tool's environment, so replies always draw on the subscription.")
            )
        ]
    }

    static var supportedAlternative: String {
        String(localized: "For a metered path on Anthropic's commercial terms, add the Claude provider with an API key instead.")
    }
}
