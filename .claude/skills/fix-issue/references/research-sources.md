# Research Sources

Where the platform lane looks and which tools it uses. The aim is to ground the fix in documented
platform behavior, not in guesswork. Read this in the lane, not in the main thread.

## Tools

No MCP server is configured in this repository. Everything below is a built-in tool or a file on
disk.

| Tool | Use for |
| --- | --- |
| `Grep` over the SDK `.swiftinterface` files | Confirming a symbol exists, its exact signature, and its `@available` annotations, for the toolchain we actually build with. Authoritative and offline. Path below. |
| `LSP` | Symbol definitions, references, and hover types inside the repository. Faster and more exact than grep for "who calls this". |
| `WebSearch` | Finding the right HIG page, Apple sample code, WWDC session notes, competitor docs. |
| `WebFetch` | Reading a specific page once you have the URL. |
| `Read` over `docs/` | TablePro's own shipped documentation, so a fix does not contradict what users have been told. |

### The local SDK interface files

```
/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64e-apple-macos.swiftinterface
```

`AppKit`, `SwiftUI`, `Foundation`, and the rest are all there. This is ground truth for "does this
API exist and what is its signature", because it is the interface the compiler reads. Web docs
describe intent; the interface file settles facts. Use both: the interface for the signature, the
docs for the behavior. Xcode-beta is the only Xcode installed.

## Apple documentation

- **Human Interface Guidelines**: `https://developer.apple.com/design/human-interface-guidelines`.
  The macOS sections on windows, panels, sheets, toolbars, sidebars, menus, tables and lists, and
  selection are the usual ones for a database client. Quote the specific guideline. "The HIG says
  so" without a citation is not evidence.
- **AppKit**: `https://developer.apple.com/documentation/appkit`. Native windows, sheets,
  `NSToolbar`, `NSTableView` and `NSOutlineView`, `NSWindow` tabbing, the responder chain, menus,
  `NSViewController`.
- **SwiftUI**: `https://developer.apple.com/documentation/swiftui`. TablePro is SwiftUI first with
  AppKit where SwiftUI falls short. Check whether a native SwiftUI modifier already does the job
  before dropping to AppKit, and check the reverse too: several TablePro views are AppKit
  precisely because the SwiftUI equivalent misbehaves. `AGENTS.md` and the project guide record
  those constraints.
- **Deprecations matter.** Name the modern API. If the only documented option is deprecated, say
  so and name the replacement.
- **Availability matters.** TablePro targets macOS 14. An API introduced later needs an
  `if #available` branch, and the blueprint has to say what the fallback is.

## Competitor behavior

Native macOS database clients worth checking when the question is "what should this feel like":
TablePlus, DataGrip, Postico, and Sequel Ace, whose source is inspectable. An issue reporter
describing how something "should" work is often describing the client they came from.

Matching another client is not a goal on its own. Where a competitor and the HIG disagree, the HIG
wins and the blueprint says why. You cannot run these apps from here, so rely on their
documentation and changelogs, and label confirmed behavior separately from inference.

## What good evidence looks like

- Code: `Path/To/File.swift:123` plus one line on what is there.
- Platform: a doc URL or exact symbol name with the rule quoted, plus the `.swiftinterface` line
  when the question is whether an API exists.
- Measured: the probe you built, the command you ran, and its output.

Thin or missing evidence is fine to report as long as it is labeled. A confident wrong claim is
worse than an honest "could not confirm", because the writer spends a verification cycle
disproving it.
