# Editor discard and final-tab recheck

Follow-up for [issue 1333](https://github.com/cozyGarage/BookiE/issues/1333). The existing installed-app scenario `closing_a_dirty_file_with_discard_closes_without_writing` passed without retries on the [pinned release executable](result.json). It modifies a restored file, discards it, verifies the file stayed unchanged, closes the last remaining tab, clicks the empty-state Open SQL editor button with actual pointer input and completes a new query.

The run used private Xvfb/Cairo and D-Bus. It does not reproduce or disprove the broader native Wayland freeze. The issue remains open for that scope. No production code or test assertion changed.

A separate existing toolbar scenario passed without retries in 3.165 seconds on the same executable at window widths 928, 847 and 802 pixels. It checks action allocations in a narrow workspace. It does not test streaming status or larger text, so it does not complete issue 1279 acceptance.
