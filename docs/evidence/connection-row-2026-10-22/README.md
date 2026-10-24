# Saved connection row readability, 2026-10-22

## Scope

Tracks [#1332](https://github.com/cozyGarage/BookiE/issues/1332) and the narrow-popover report [#1328](https://github.com/cozyGarage/BookiE/issues/1328). The shared row appears in both the welcome list and the saved-connection popover. This work does not establish the cause of the separately reported editor freeze.

## Reproduction and change

The regression was first run against Linux `9b8bb2897b39bf4ddb6e8952ab641894f1b74a9c`, before changing the row. With a 320-pixel list and 20-pixel text, the connection name received only 32 pixels. The allocation assertion failed.

The row keeps Favorite and Open visible. Group and tags, Edit, Duplicate and Remove move into one native popover. Title and endpoint each occupy one line; the full name and endpoint remain in the tooltip. Saved names render as plain text. The existing removal confirmation remains in place.

The revised allocation test passes with at least 120 pixels reserved for the name. The installed popover exposed 154-pixel name and endpoint allocations at the default text size. The action test checks that organization, edit and duplication dispatch the selected record's ID.

An initial menu-model implementation rendered all four actions but did not expose its entries through AT-SPI in the local GTK build. It was replaced with native labeled buttons. The installed tests interact with those buttons rather than bypassing them through exported actions.

## Separate defect

Removal was also exercised without deleting any fixture data. It displayed `Remove “name”?` followed by `Delete name?`. Cancelling the second confirmation preserved the complete saved-connection file. Both handlers predate the layout change. [#1337](https://github.com/cozyGarage/BookiE/issues/1337) tracks removing this duplicate prompt while preserving unconditional confirmation at the application boundary.

## Verification

- Narrow allocation regression: failed before the change, passed after it under Xvfb.
- Selected-record action dispatch: passed under an isolated display.
- Installed Edit flow: passed, including saved name and connection-count assertions.
- Installed Group and tags flow: passed, including the accessible color chooser.
- GTK widget tier: 105 tests passed.
- Preflight: passed; the distro package check reported that `dpkg-deb` is unavailable locally.
- Refreshed onto Linux `6caa27f18` after #1331 and #1324. Final preflight, 713 application unit tests and application all-target Clippy passed.
- The merge changed no application Rust code, crate source or isolated-test registrations relative to the widget-tested candidate. This was checked with `git diff 86a6d7681 HEAD -- apps/linux/app crates scripts/isolated-tests.json`.
- [Manifest](manifest.json) records the saved binary checksum and installed case results. Forgejo acceptance was pending at this evidence checkpoint.

Raw local logs are outside the repository. Checks use isolated X11 displays and session buses. The native Wayland desktop, screen-reader narration, light theme and high contrast have not yet been verified for this change.

## Subsequent status

GitHub PR [#1338](https://github.com/cozyGarage/BookiE/pull/1338) merged on 2026-10-22 at head `8aa41c861d7273aa1a0c0225fbd96e5df871eeda`, and issue [#1328](https://github.com/cozyGarage/BookiE/issues/1328) closed. Its merge commit is in the current Linux tree. The PR's GitHub checks included failures before merge, and this packet does not identify the exact-head Forgejo run; [#1543](https://github.com/cozyGarage/BookiE/issues/1543) tracks the merge-order and gate-evidence audit. Native Wayland and accessibility acceptance listed above remain unverified.
