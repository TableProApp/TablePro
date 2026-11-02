# Architecture Decision Records

Decisions only the Windows app makes: its toolchain, its packaging and how it builds on the shared core. A decision that holds for every platform goes in [`core/docs/decisions/`](../../../core/docs/decisions/README.md).

The format, the statuses and how a later ADR changes an earlier one follow [the Linux decisions' README](../../../linux/docs/decisions/README.md).

## Index

| # | Title | Status | Summary |
|---|---|---|---|
| [0001](0001-toolchain-baseline.md) | Windows toolchain and build baseline | Accepted | Build Tools for Visual Studio 2026 with MSVC for x64 and Arm64, Windows SDK 10.0.26100, .NET 10 and Rust with both MSVC targets; cargo runs from the csproj; Native AOT; Windows 10 1809 as the floor, with runtime checks for Windows 11 behavior. |
