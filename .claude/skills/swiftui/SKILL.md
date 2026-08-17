---
name: swiftui
description: TablePro's SwiftUI and AppKit view rules. Use when writing or reviewing a view, view model, window, settings pane, or accessibility identifier in TablePro or TableProMobile. It carries the rules this repository's targets and conventions actually decide, not generic framework advice.
---

# SwiftUI in TablePro

Generic SwiftUI advice is wrong here often enough to be dangerous. This app is a deliberate
hybrid, its macOS target is older than most sample code assumes, and several of its conventions
are the opposite of the usual defaults. Only the rules below are TablePro rules.

## The hybrid is deliberate

TablePro is SwiftUI first and drops to AppKit where SwiftUI cannot hold the behavior: window and
tab ownership, the responder chain, menus, split-view geometry, table performance, and sizing.
`MainSplitViewController` is an `NSSplitViewController` replacing `NavigationSplitView` on purpose.

Before replacing an AppKit view with SwiftUI, search the project guide for that view's invariant.
If the guide records a lifecycle, responder-chain, sizing, menu, window, table, or performance
reason, that reason still holds. Replacing it reintroduces a shipped bug.

The reverse also applies: check whether a native SwiftUI modifier already does the job before
writing an `NSViewRepresentable`.

## Targets

| Target | Deployment | Concurrency |
| --- | --- | --- |
| `TablePro` (macOS) | macOS 14 | Swift 5 mode, `SWIFT_APPROACHABLE_CONCURRENCY`, **no** default actor isolation |
| `TableProMobile` (iOS) | iOS 18 | same, plus `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` |

Consequences that decide real code:

- An API introduced after macOS 14 needs `if #available` and a stated fallback. Check the installed
  SDK `.swiftinterface`, not a blog post. `Tab`, `.searchFocused`, and
  `EnumeratedSequence` as a `RandomAccessCollection` are all past macOS 14 and do not compile here.
- On the macOS target, an `@Observable` class that drives UI needs an explicit `@MainActor`. There
  is no default isolation to inherit. On the iOS target there is, so the same type written for
  mobile may legitimately omit it.
- iOS-only API is a hard compile error in the macOS app, which is most of the codebase. No
  `UIScreen`, no `keyboardType`, no `.topBarLeading`, no 44 by 44 touch targets. macOS colors are
  `NSColor`.

## State and storage

- `@AppStorage` must resolve its store through `AppStorageEnvironment.shared.defaults`, and plain
  `UserDefaults.standard` is a SwiftLint error outside the few macOS-owned preference sites. A UI
  test that writes the developer's real store is the failure this prevents.
- Never put a credential, token, or secret in `@AppStorage`. Credentials go to the Keychain.
- `@AppStorage` inside an `@Observable` class never triggers a view update, with or without
  `@ObservationIgnored`. Read it from the view, or publish an explicit change.
- Do not cache a derived collection in `@State` unless you own its invalidation. Recompute, or
  make the dependency explicit.

## Concurrency

Prefer Swift concurrency. `DispatchQueue.main.async` is allowed for one purpose: deferring by a
single run-loop turn out of an AppKit callback, where doing the work inline reenters something that
is not reentrant. State the reason at the call site. `DispatchQueue.main.sync` is allowed only where
a sheet or modal would otherwise deadlock, and the existing sites say so.

Never use `Task.detached` to escape actor isolation. Keep UI state mutation on its owning actor.

## Deprecated but silent

These are marked deprecated with a version so high the compiler emits nothing, so nothing warns
you and reviews are the only gate:

`foregroundColor` (use `foregroundStyle`), `cornerRadius` (use `clipShape` or
`.rect(cornerRadius:)`), `overlay(_:alignment:)` (use the trailing-closure form),
`ScrollView(showsIndicators:)` (use `.scrollIndicators`), `NavigationView` (use
`NavigationStack`, or the AppKit split view this app actually uses).

## Accessibility

- An icon-only `Button` or `Menu` carries a text label. UI automation resolves elements by label,
  so an unlabeled control is both inaccessible and untestable.
- Never put `.accessibilityIdentifier` on a SwiftUI container by itself: it replaces the identifier
  of every descendant in the same hosting tree. Pair it with
  `.accessibilityElement(children: .contain)`, in that order.
  `.claude/skills/fix-issue/references/verification.md` holds the measured detail and the
  accessibility-tree traps that differ between this machine and CI.

## File organization

Do not extract every computed `some View`. This repository has hundreds of them and files that
declare several small types, deliberately, organized by domain. The limits in `.swiftlint.yml` are
the actual rule: flag a view when it pushes a file or type past them, and extract into
`TypeName+Domain.swift` when it does.

## Text

User-facing strings in AppKit and computed strings use `String(localized:)`. SwiftUI string
literals localize automatically. The catalog is keyed on the English source string, so never
interpolate inside a key and never hand-author catalog entries or extraction states.

## Reviewing

Report findings as `file:line`, what breaks, and the smallest fix. Do not report taste, and do not
report a rule from this file that the repository deliberately violates at that site: check the
project guide first, then say the site is wrong.
