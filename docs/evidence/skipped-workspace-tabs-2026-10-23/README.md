# Empty workspace restoration after skipped records

Issue: [#1509](https://github.com/cozyGarage/BookiE/issues/1509). Baseline: Linux `0053bf339`.

The UI selects its empty state when the normalized saved tab list is empty. Empty structure-table records survived normalization but were later skipped by restored_workspace_tab. The UI therefore selected a tab workspace without restored pages, and a skipped record could also offset the saved active index.

Two normalization regressions failed before the correction: an all-skipped record list remained nonempty, and a skipped record before the active editor remained in the list. The existing retention/index-mapping helper now removes empty structure records in both legacy and modern formats, using the same selected-index remapping already used for unknown tabs. Editor drafts and valid table records are not filtered.

All 288 app-services unit tests and full preflight pass. The installed scenario fails on the freshly rebuilt unfixed Linux binary: selecting page 0 after every record is skipped causes adw_tab_view_get_nth_page to raise a fatal position < self->n_pages critical, preventing the expected restored window. On the corrected debug binary the same retry-free Xvfb scenario passes: it restores the isolated workspace, physically clicks Open SQL editor and executes SELECT 9 successfully (3.563 seconds including harness activity). Forgejo acceptance remains pending. This correction does not establish resolution of the broader native freeze report #1333.

Existing installed scenarios were also rechecked against the same corrected binary with retries disabled: restart_restores_active_editor_and_connection passed (12.099 seconds) and closing_a_clean_editor_tab_removes_it_and_keeps_the_other passed (2.350 seconds). These confirm the tested valid-workspace and clean-close flows remain usable; the service regression separately covers selected-index remapping across a skipped record.
