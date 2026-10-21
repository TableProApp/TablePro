# PostgreSQL terminal cursor metadata, October 22

Issue [#1302](https://github.com/cozyGarage/BookiE/issues/1302) records exact-page-multiple queries failing when an empty terminal page carries metadata with different type-name casing from preceding populated pages.

The initial PR #1304 changed shared statement metadata casing. Forgejo run 856 rejected that change in `value_contract_result_delivery_keeps_zero_row_metadata_duplicate_names_and_order`: the existing zero-row contract expects lowercase type names. That failure is a code/test contract mismatch, not infrastructure evidence.

The corrected implementation preserves shared statement metadata and the existing zero-row assertions. It uses the active cursor's cached columns on an empty terminal page, before considering new page metadata. An initially empty result still uses its own metadata. Populated pages continue to supply their actual columns; consumer schema checks remain unchanged.

The exact-page-multiple regression compares full column metadata on every page, including the final empty one. It failed on the original implementation and passed after this cursor-local correction. All five `query_cursor_` PostgreSQL integration cases passed locally. The full Docker-backed PostgreSQL integration selection also passed: 285 passed, zero failed, two non-ignored tests filtered out, in 443.75 seconds. The unchanged zero-row contract passed alongside the cursor regression. Formatting, function-size and comment-line checks passed. Full preflight passed after merging documentation-only linux updates through `2d442f6eb`. The revised Forgejo gate remains pending.
