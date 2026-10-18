<!--
Title: <type>(<scope>): <description>, with ! before the colon for a breaking change. At most 72 characters, GitHub's " (#123)" not counted. It becomes the squash commit subject.
Types: feat, fix, refactor, perf, test, docs, build, ci, chore, style, revert.
Scopes, when one fits: ai-chat, ai-providers, mcp, copilot, inline-suggest, editor, datagrid, tabs, coordinator, sidebar, connections, connection-form, welcome, settings, toolbar, hig, ssh, ios, windowing, perf, launch, plugins, plugin-<name>, changelog, claude-md, docs, ci, release.
Platform scopes: ios for the iOS app, linux or linux-<area> for the Linux app. windows is kept for a Windows app, so window management is windowing.
Body: 80 to 150 words, 250 at most, screenshots aside. Delete these comments and any optional heading you do not use.
Leave out review history, test lists and counts, the investigation story and file-by-file change logs.
The PR title check also scans this body against scripts/banned-words.txt.
-->

## Why

<!-- Bug: what the user saw, then the cause in one or two sentences. Feature: what the user could not do before. -->

## Change

<!-- One to four bullets, in the user's terms first. One bullet per fix when the PR carries several. -->

## Verified

<!-- One or two lines: the test that fails on main and passes here, and any check on a real build. Name each existing test this PR changed because it pinned behavior the PR changes on purpose. A new end-to-end flow without a UI test says why. -->

## Screenshots

<!-- Optional. Only when the UI changes: before and after, light and dark when color is involved. -->

## Not in this PR

<!-- Optional. A known gap, a follow-up, or a risk the reviewer should weigh. One line each. -->

Fixes #
<!-- One keyword per issue ("Fixes #1, fixes #2"), "Refs #N" for one this does not close. Delete the line when there is no issue. -->
