# Architecture Decision Records

Decisions only the Windows app makes: its toolchain, its packaging and how it builds on the shared core. A decision that holds for every platform goes in [`core/docs/decisions/`](../../../core/docs/decisions/README.md).

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md).

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-toolchain-baseline.md) | Windows toolchain and build baseline | Accepted; amended by 0005 | Build Tools for Visual Studio 2026 with MSVC for x64 and Arm64, Windows SDK 10.0.26100, .NET 10 and Rust with both MSVC targets; cargo runs from the csproj; Native AOT; Windows 10 1809 as the floor, with runtime checks for Windows 11 behavior. |
| [0002](0002-sql-editor-control.md) | TablePro's own SQL editor control | Accepted | A rope with its own undo in a plain .NET model, drawn with Direct2D and DirectWrite into a SwapChainPanel, TSF as Windows Terminal does it, a UIA text provider, and the core's lexer for colors. |
| [0003](0003-data-grid-control.md) | TablePro's own data grid control | Accepted | A read-only WinUI 3 control: ItemsRepeater rows that draw their visible cells with DirectWrite into composition surfaces through the editor's drawing layer, cells as UIA peers with no element, data read from the core in windows of cells. |
| [0004](0004-app-shell.md) | The app shell | Accepted; packaging amended by 0005 | One window with the TitleBar, a MenuBar and a NavigationView rail of open connections, each with its own TabView; the Connections page, an owned connection form window, Settings as a page; the core keeps connections and Credential Manager secrets, the app its settings and session in LocalState. |
| [0005](0005-distribution.md) | Shipping the app | Accepted | One self-contained Native AOT MSIX per architecture in an `.msixbundle` signed with Azure Artifact Signing, on GitHub Releases and winget; the core on the hybrid CRT; the 1809 floor checked in the package and on Windows Server 2022. |
