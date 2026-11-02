# Architecture Decision Records

Decisions only the Windows app makes: its toolchain, its packaging and how it builds on the shared core. A decision that holds for every platform goes in [`core/docs/decisions/`](../../../core/docs/decisions/README.md).

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md).

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-toolchain-baseline.md) | Windows toolchain and build baseline | Accepted | Build Tools for Visual Studio 2026 with MSVC for x64 and Arm64, Windows SDK 10.0.26100, .NET 10 and Rust with both MSVC targets; cargo runs from the csproj; Native AOT; Windows 10 1809 as the floor, with runtime checks for Windows 11 behavior. |
| [0002](0002-sql-editor-control.md) | TablePro's own SQL editor control | Accepted | A rope with its own undo in a plain .NET model, drawn with Direct2D and DirectWrite into a SwapChainPanel, TSF as Windows Terminal does it, a UIA text provider, and the core's lexer for colors. |
| [0004](0004-app-shell.md) | The app shell | Accepted | One window with the TitleBar, a MenuBar and a NavigationView rail of open connections, each with its own TabView; the Connections page, an owned connection form window, Settings as a page; the core keeps connections and Credential Manager secrets, the app its settings and session in LocalState. |
