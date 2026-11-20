# 0021: Localizing the app

- **Status**: Accepted
- **Date**: 2026-11-20

## Context

The app's views read their words from `Strings/en-US/Resources.resw` ([0004](0004-app-shell.md), Strings and accessibility), but the editor's context menu and find bar, the grid's statuses and its unreadable cell, the title bar, some menu shortcuts and the package manifest were English in code. Plural forms were chosen in code by comparing a count with one, an English rule: Polish needs few and many, Arabic zero and two. The maintainer chose English only for now (2026-11-19), and a language added later must need only a new `.resw`.

## Decision

- **One file per language.** Every word is in `Strings/<language>/Resources.resw` of `TablePro.App`, as [Localize strings in your UI and app package manifest](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/mrtcore/localize-strings) describes: XAML through `x:Uid` and its property identifiers, `KeyboardAcceleratorTextOverride` included; code through `Strings`; the manifest through `ms-resource:`. The manifest keeps `x-generate`, so a new folder adds its language to the package.
- **The controls read the host's words.** `TablePro.Editor` and `TablePro.DataGrid` read the hosting app's `Resources` map through `HostStrings` in `TablePro.Graphics`, as the docs advise a class library to; a host without the strings gets empty text. The grid's statuses stay settable for a host that words them otherwise. `DataGrid.Tests` and `Editor.Tests` link the app's file so they read the real words.
- **Plurals by CLDR category.** `Strings.Plural(name, count, values)` reads `name_<category>`, else `name_other`, where the category comes from the plural rules of the ICU that Windows ships (`uplrules_select`; `icu.dll` from Windows 10 1903, `icuin.dll` from 1703), for the language the string resolved in (`ResourceCandidate.QualifierValues["Language"]`). English has `_one` and `_other`; a language adds the forms it needs. The count only chooses the form; the values carry it wherever the sentence shows it.
- **Numbers through the platform.** A count is `{n:N0}` in the user's culture. A size is `StrFormatByteSizeEx`, File Explorer's own wording, in Windows' language.
- **No sentence built in code.** Joins are strings too: `ListSeparator`, `JoinSentences`, `JoinDot`, `JoinLabelValue`, `JoinParenthetical`, so a language can change the punctuation and the order. SQL, paths, `user@host` and error codes stay as written.
- **A check.** `LocalizationTests` in `TablePro.App.Model.Tests` reads the sources: a word in XAML outside `x:Uid`, a literal set on a control's text, tooltip or UIA name in code, a count compared with one to pick a string, a name the code reads that the file lacks, a plural without `_other`, or a manifest name without `ms-resource:` fails it.

## Rationale

- Microsoft recommends that a library load its strings from the app that hosts it, which keeps one file per language. A `.resw` per control library would make each language three files.
- MRT Core and `.resw` have no plural forms. Windows ships ICU with CLDR's rules on every supported version, so the rule is the platform's and the forms are data in the `.resw`, as Android's plurals and Apple's string catalogs keep them.
- The resolved string's language, not the user's culture, picks the rule: a Polish user of an app without Polish reads English, which takes English's rule.

## Consequences

- A word added in code without the resource reads empty; the check catches the common shapes, and a helper that passes a literal on to a control is caught only in review.
- The editor's and the grid's tests need the app's file in their host; the grid's gate shows empty statuses, which it does not read.
- A right-to-left language needs more than a `.resw`: the windows' `FlowDirection` and the drawn editor and grid would have to mirror. That is layout work, not strings.
- An unpackaged development build resolves strings in the Windows display language, a packaged one in the user's preferred languages, as MRT Core does.

## Alternatives considered

- **`count == 1` with One and Many keys**: what the app did. A language with other forms needs code.
- **ICU MessageFormat strings**: one string per sentence with every form inside, but its C API takes variadic arguments, which C# cannot pass without a binding per call shape.
- **A `.resw` in each control library, loaded from its own subtree**: works, but a language becomes three files and the host cannot reword the controls.
