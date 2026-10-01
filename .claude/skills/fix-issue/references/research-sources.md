# Research sources

Where to find the correct behavior, and what counts as evidence for it.

## Apple platform

- **SDK interface, the ground truth for whether an API exists and what its signature is**:
  `$(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/<Framework>.framework/Modules/<Framework>.swiftmodule/arm64e-apple-macos.swiftinterface`.
  Grep it for the symbol and its `@available`. It is what the compiler reads, so web docs give the intent and this file settles the facts.
- **Human Interface Guidelines**: `https://developer.apple.com/design/human-interface-guidelines`. For a database client the macOS sections that matter most are windows, panels, sheets, toolbars, sidebars, menus, tables and lists, and selection. Quote the rule; "the HIG says so" without a quote is not evidence.
- **AppKit** (`https://developer.apple.com/documentation/appkit`) and **SwiftUI** (`https://developer.apple.com/documentation/swiftui`). Check whether a SwiftUI modifier already does the job before dropping to AppKit, and check the reverse too: several TablePro views are AppKit because the SwiftUI version misbehaves, and `CLAUDE.md` records why.
- **Availability**: the deployment target is macOS 13. An API from macOS 14, 15 or 26 needs an `if #available` branch, and the plan names the fallback. Name the modern API, and when the only option is deprecated, name its replacement.
- **TablePro's own docs** in `docs/`: a fix must not contradict what users have been told.

## Dependencies

The source is the vendored header and the library we ship, not a web page.

- Headers live under `Plugins/*/C*/include/` and `Libs/`. State the version we actually link, because a build script has named a version we never shipped.
- Quote the header's doc comments for each symbol in play, especially deprecation notes and what a call returns when it cannot do the job.
- Where the header does not settle it, compile a probe against `Libs/*.a` and report its output verbatim. A measurement outranks every document.

## Comparable clients

Use these for a new feature or a changed interaction. A reporter describing how something "should" work is usually describing the client they came from.

| Client | Why read it | Where |
| --- | --- | --- |
| TablePlus | Closest comparison, and where most users arrive from | `tableplus.com/changelog`, `docs.tableplus.com` |
| Sequel Ace | Open source, so its behavior can be read rather than inferred | `github.com/Sequel-Ace/Sequel-Ace` |
| Postico | Strongly native, a good guide to the HIG-correct version of a surface | `eggerapps.at/postico` |
| DataGrip | Deepest SQL tooling; take the capability, not the non-native interaction | `jetbrains.com/datagrip` |
| Beekeeper Studio | Open source | `github.com/beekeeper-studio/beekeeper-studio` |
| DBeaver | Widest driver and dialect coverage, for engine quirks | `github.com/dbeaver/dbeaver` |

Method: search each one's docs and changelog for the surface in its own words, since the changelog says when and why behavior changed. Read the source for the open-source ones. Write one line per client, then say where they agree, because agreement across three clients is a strong signal of what users expect. Mark each claim confirmed or inferred, since none of these apps can be run from here. Where a client and the HIG disagree, the HIG wins.

Competitor findings shape the plan and stay out of the repo: no client is named in code, commits, the PR, CHANGELOG or docs.
