# Research Sources

Where the investigators look and which tools they use. The aim is to ground the fix in documented platform behaviour and established UX, not in guesswork.

## Tools

There are no MCP servers configured in this repo. Everything below is a built-in tool or a file on disk.

| Tool | Use for |
| --- | --- |
| `Grep` over the SDK `.swiftinterface` files | Confirming a symbol exists, its exact signature, and its `@available` annotations, for the toolchain we actually build with. Authoritative and offline. Path below. |
| `WebSearch` | Finding the right HIG page, Apple sample code, competitor docs, WWDC session notes. |
| `WebFetch` | Reading a specific Apple doc or competitor help page once you have the URL. |
| `LSP` | Symbol definitions, references, and hover types inside the repo, when the session exposes the tool. It is not always present, so check before planning around it and fall back to `grep` for "who calls this". |
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

An issue reporter describing how something "should" work is usually describing the client they came from. Finding that client and reading how it actually behaves turns a vague request into a concrete specification, and it is often the fastest way to see the edge cases the reporter did not mention.

| Client | Why it is worth reading | Where |
| --- | --- | --- |
| **TablePlus** | The closest comparison, and where most of our users arrive from. Check it first. | `tableplus.com/changelog`, `docs.tableplus.com` |
| **Sequel Ace** | Open source, so behaviour can be read rather than inferred. Best source for MySQL-specific interaction detail. | `github.com/Sequel-Ace/Sequel-Ace` |
| **Postico** | Strongly native and opinionated about macOS conventions. Good when the question is what the HIG-correct version of a surface looks like. | `eggerapps.at/postico` |
| **DataGrip** | Deepest SQL tooling: completion, refactoring, diagrams, introspection. Not native macOS, so take the capability and not the interaction. | `jetbrains.com/datagrip`, their release blog |
| **Beekeeper Studio** | Open source, so its implementation of a feature is readable. | `github.com/beekeeper-studio/beekeeper-studio` |
| **DBeaver** | Broadest driver and dialect coverage. Useful for "how does anyone handle this database's quirk". | `github.com/dbeaver/dbeaver` |

The method:

1. Name the surface in the words a competitor would use, then search their docs and changelog for it. The changelog is often better than the docs, because it says when and why the behaviour changed.
2. For the open-source clients, read the code. That is observed behaviour, not inference, and it is the only way to be sure about an edge case.
3. Write down what each one does in one line, then say where they agree. Convergence across three clients is a strong signal about what users will expect.
4. Note what they get wrong, or what their users complain about. A competitor's shipped behaviour is not automatically correct, and their issue trackers are public.
5. Label every finding CONFIRMED or INFERRED. You cannot run these apps from here, so anything not read in source or stated in their documentation is inference.

Matching TablePlus is not the goal on its own, and neither is differing from it. Where a competitor and the HIG disagree, the HIG wins and the blueprint says why. Keep the findings in the blueprint and the PR body; this repository deliberately carries no competitive comparison content in `docs/`.

## What good evidence looks like

- Code: `Path/To/File.swift:123` plus a one-line note on what is there.
- Platform: a doc URL or exact symbol name (`NSWindow.toggleToolbarShown`, the HIG "Sheets" section), with the relevant rule quoted, and the `.swiftinterface` line when the question is whether an API exists.
- Competitor: the source (docs page, release note) and whether it is confirmed or inferred.

Thin or missing evidence is fine to report as long as it is labelled. A confident wrong claim is worse than an honest "could not confirm".
