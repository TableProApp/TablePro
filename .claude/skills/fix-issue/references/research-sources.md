# Research Sources

Where the investigators look and which tools they use. The aim is to ground the fix in documented platform behaviour and established UX, not in guesswork.

## Tools

| Tool | Use for |
| --- | --- |
| `mcp__xcode__DocumentationSearch` | AppKit / SwiftUI / Foundation symbol docs, available offline from the local Xcode docset. First stop for "what does this API do / what's the right one". |
| `WebSearch` | Finding the right HIG page, Apple sample code, competitor docs, WWDC session notes. |
| `WebFetch` | Reading a specific Apple doc or competitor help page once you have the URL. |
| `mcp__plugin_mintlify_Mintlify__*` | TablePro's own docs (`docs/`, Mintlify). Use to learn the *currently documented* TablePro behaviour, so a fix doesn't contradict shipped docs. |

Prefer the Xcode docs tool for API questions: it's authoritative and version-matched. Use the web for design intent (HIG) and competitor behaviour.

## Apple documentation map

- **Human Interface Guidelines** — `https://developer.apple.com/design/human-interface-guidelines`. The macOS sections on windows, panels, sheets, toolbars, sidebars, menus, tables/lists, and selection are the usual ones for a database client. Quote the specific guideline; "the HIG says so" without a citation isn't evidence.
- **AppKit** — `https://developer.apple.com/documentation/appkit`. For native windows, sheets, `NSToolbar`, `NSTableView`/`NSOutlineView`, `NSWindow` tabbing, responder chain, menus, `NSViewController`.
- **SwiftUI** — `https://developer.apple.com/documentation/swiftui`. TablePro is SwiftUI-first with AppKit where SwiftUI falls short. Check whether a native SwiftUI modifier already does the job before dropping to AppKit.
- **Deprecations matter.** Name the modern API. If the only documented option is deprecated, say so and note the replacement.

## Competitor apps

Native macOS database clients worth checking for expected behaviour:

- **DataGrip** — JetBrains, feature-rich; good for data-grid and SQL-editor behaviour.
- **Postico** — native macOS Postgres client, strong HIG conformance; good model for "what feels native on macOS".
- **Sequel Ace** — open-source MySQL client; behaviour is inspectable.

You can't run these apps from here, so rely on their documentation, changelogs, support articles, and credible written descriptions. Distinguish confirmed behaviour from inference, and say which is which in the report.

## What good evidence looks like

- Code: `Path/To/File.swift:123` plus a one-line note on what's there.
- Platform: a doc URL or exact symbol name (`NSWindow.toggleToolbarShown`, HIG "Sheets" section), with the relevant rule quoted.
- Competitor: the source (docs page, release note) and whether it's confirmed or inferred.

Thin or missing evidence is fine to report as long as it's labelled. A confident wrong claim is worse than an honest "couldn't confirm".
