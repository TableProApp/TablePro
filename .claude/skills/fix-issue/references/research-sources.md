# Research Sources

Where the investigators look and which tools they use. The aim is to ground the fix in documented platform behaviour and established UX, not in guesswork.

## Tools

There are no MCP servers configured in this repo. Everything below is a built-in tool or a file on disk.

| Tool | Use for |
| --- | --- |
| `Grep` over the SDK `.swiftinterface` files | Confirming a symbol exists, its exact signature, and its `@available` annotations, for the toolchain we actually build with. Authoritative and offline. Path below. |
| `WebSearch` | Finding the right HIG page, Apple sample code, competitor docs, WWDC session notes. |
| `WebFetch` | Reading a specific Apple doc or competitor help page once you have the URL. |
| `LSP` | Symbol definitions, references, and hover types inside the repo (the `swift-lsp` plugin is enabled). Faster and more exact than grep for "who calls this". |
| `Read` over `docs/` | TablePro's own shipped documentation (Mintlify source, in-repo). Check it so a fix does not contradict what users have been told. |

### The local SDK interface files

```
/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64e-apple-macos.swiftinterface
```

`AppKit`, `SwiftUI`, `Foundation`, and the rest are all there. This is the ground truth for "does this API exist and what is its signature", because it is the interface the compiler will read. Web docs describe intent; the interface file settles facts. Use both: the interface for the signature, the docs for the behaviour.

## Apple documentation map

- **Human Interface Guidelines**: `https://developer.apple.com/design/human-interface-guidelines`. The macOS sections on windows, panels, sheets, toolbars, sidebars, menus, tables and lists, and selection are the usual ones for a database client. Quote the specific guideline. "The HIG says so" without a citation is not evidence.
- **AppKit**: `https://developer.apple.com/documentation/appkit`. Native windows, sheets, `NSToolbar`, `NSTableView` and `NSOutlineView`, `NSWindow` tabbing, the responder chain, menus, `NSViewController`.
- **SwiftUI**: `https://developer.apple.com/documentation/swiftui`. TablePro is SwiftUI-first with AppKit where SwiftUI falls short. Check whether a native SwiftUI modifier already does the job before dropping to AppKit, and check the reverse too: several TablePro views are AppKit precisely because the SwiftUI equivalent misbehaves, and `CLAUDE.md` records why.
- **Deprecations matter.** Name the modern API. If the only documented option is deprecated, say so and note the replacement.
- **Availability matters.** TablePro targets macOS 14. An API introduced in 15 or 26 needs an `if #available` branch and a fallback, and the blueprint has to say what the fallback is.

## Competitor apps

Native macOS database clients worth checking for expected behaviour:

- **TablePlus**: the closest comparison, since TablePro is positioned as a fast, lightweight alternative to it. Check it first: users arriving from TablePlus carry its interaction habits, and an issue reporter describing "how it should work" is often describing TablePlus. Its release notes and help docs are the usable sources.
- **DataGrip**: JetBrains, feature-rich. Good for data-grid and SQL-editor behaviour.
- **Postico**: native macOS Postgres client, strong HIG conformance. A good model for what feels native on macOS.
- **Sequel Ace**: open-source MySQL client, so its behaviour is inspectable in source.

Matching TablePlus is not the goal on its own. Where TablePlus and the HIG disagree, the HIG wins and the blueprint says why.

You cannot run these apps from here, so rely on their documentation, changelogs, support articles, and credible written descriptions. Distinguish confirmed behaviour from inference and label which is which.

## What good evidence looks like

- Code: `Path/To/File.swift:123` plus a one-line note on what is there.
- Platform: a doc URL or exact symbol name (`NSWindow.toggleToolbarShown`, the HIG "Sheets" section), with the relevant rule quoted, and the `.swiftinterface` line when the question is whether an API exists.
- Competitor: the source (docs page, release note) and whether it is confirmed or inferred.

Thin or missing evidence is fine to report as long as it is labelled. A confident wrong claim is worse than an honest "could not confirm".
