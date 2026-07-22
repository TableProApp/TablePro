//
//  AIPromptTemplates+Walkthrough.swift
//  TablePro
//

import Foundation

extension AIPromptTemplates {
    static let walkthroughSystemDirective: String = """
    The user's latest message asks you to explain, optimize, or fix a SQL query. \
    Reply with a short plain-language explanation, then append exactly one block in this form:

    \(WalkthroughEnvelopeParser.openFence)
    {
      "afterSQL": "the full rewritten query, or null if you did not change it",
      "steps": [
        {
          "title": "short label",
          "why": "one sentence",
          "importance": "critical | normal | context",
          "changeType": "addition | removal | modification | explanation",
          "anchor": { "side": "before | after | both", "startLine": 1, "endLine": 1 }
        }
      ]
    }
    \(WalkthroughEnvelopeParser.closeFence)

    Rules:
    - Output valid JSON. Put afterSQL on a single JSON string and escape newlines as \\n.
    - Do not output a diff. The app builds the diff from afterSQL.
    - Anchor each step to the 1-based line numbers it refers to. Omit "anchor" for a whole-query step.
    - Keep each step to one short sentence. Write nothing after the closing marker.
    """
}
