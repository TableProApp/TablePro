use relm4::ComponentSender;

use super::*;

impl BrowseTab {
    pub(super) fn handle_duplicate_row(&mut self, row_position: u32, sender: ComponentSender<Self>) {
        if self.current_columns.is_empty() {
            return;
        }
        // Read the source row through the live RowObject at
        // `row_position` — NOT by indexing
        // `current_result.rows` directly. The grid's
        // row_position reflects the user's current sort and
        // any prepended drafts; raw `rows` is fetch order. A
        // sort would otherwise hand us the wrong row's cells.
        let Some(source) = self.row_object_at(row_position) else {
            return;
        };
        let source_cells = source.cells_clone();
        let values = match duplicate_row_values(&self.current_columns, &source_cells) {
            Ok(values) => values,
            Err(DuplicateRowError::Undecodable { column }) => {
                let message = crate::tr!("Cannot duplicate this row because column {name} is undecodable.")
                    .replace("{name}", &column);
                let _ = sender.output(BrowseTabOutput::ShowToast(message));
                return;
            }
            Err(DuplicateRowError::CellCountMismatch { expected, actual }) => {
                let message =
                    crate::tr!("Cannot duplicate this row because it has {actual} values for {expected} columns.")
                        .replace("{actual}", &actual.to_string())
                        .replace("{expected}", &expected.to_string());
                let _ = sender.output(BrowseTabOutput::ShowToast(message));
                return;
            }
        };
        let key_opt = crate::services::change_tracker::with_tab(self.tab_id, |t| t.track_insert(values.clone()));
        let Some(key) = key_opt else {
            return;
        };
        let crate::services::change_tracker::RowKey::Draft(draft_id) = key else {
            return;
        };
        if let Some(store) = self.list_store() {
            let draft_row = crate::ui::row_object::RowObject::new_draft(draft_id, values);
            store.insert(0, &draft_row);
        }
        self.refresh_inner_stack_visibility();
        // Scroll + focus deferred via FocusInsertedDraft — see
        // the matching note in the `InsertRow` arm above. Same
        // `bounds.y == 0` assertion fires if `cv.scroll_to`
        // lands in the same tick as a stack flip.
        sender.input(BrowseTabInput::FocusInsertedDraft);
    }

    pub(super) fn handle_insert_row(&mut self, sender: ComponentSender<Self>) {
        if self.current_columns.is_empty() {
            return;
        }
        // Inline draft: track in the changeset (returns a
        // RowKey::Draft(N) handle), then prepend a fresh
        // RowObject tagged with the same draft id to the
        // grid's ListStore. The new row appears at the top
        // with a green tint and editable cells; user fills
        // them inline and clicks Save to commit.
        let default_values: Vec<Value> = self.current_columns.iter().map(|_| Value::Null).collect();
        let key_opt =
            crate::services::change_tracker::with_tab(self.tab_id, |t| t.track_insert(default_values.clone()));
        let Some(key) = key_opt else {
            return;
        };
        let crate::services::change_tracker::RowKey::Draft(draft_id) = key else {
            return;
        };
        if let Some(store) = self.list_store() {
            let draft_row = crate::ui::row_object::RowObject::new_draft(draft_id, default_values);
            store.insert(0, &draft_row);
        }
        // The empty-state status page hides the column view —
        // if we were sitting on it (zero persisted rows on the
        // first page) the draft we just appended would be
        // invisible. Re-derive the inner stack visibility now
        // that there's a draft to show.
        self.refresh_inner_stack_visibility();
        // Scroll + focus are deferred via FocusInsertedDraft.
        // Calling `cv.scroll_to(...)` synchronously here used
        // to crash with
        //   Gtk-ERROR gtk_list_base_update_adjustments:
        //   assertion failed: (bounds.y == 0)
        // when the empty → grid flip and the scroll landed in
        // the same tick: the ColumnView's ScrolledWindow had
        // no realized adjustments to update. FocusInsertedDraft
        // runs from `glib::idle_add_local_once`, after GTK has
        // finished allocating the now-visible grid, so the
        // adjustments are valid by then.
        sender.input(BrowseTabInput::FocusInsertedDraft);
    }

    pub(super) fn handle_delete_selected_row(&mut self, sender: ComponentSender<Self>) {
        // Toolbar Delete now marks the selected rows for
        // pending deletion (red strikethrough via tracker
        // overlay). User reviews + clicks Save to commit, or
        // Discard / Ctrl+Z to revert. Replaces the previous
        // confirm-dialog-then-immediate-DELETE flow.
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let positions = selected_positions(selection);
        if positions.is_empty() {
            return;
        }
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        // Partition the selection into persisted rows (need a
        // PK to build a RowKey) and drafts (in-memory only,
        // discarded by id). We resolve through the selection
        // model rather than `result.rows[pos]` directly
        // because `pos` is in selection-model space, which
        // includes prepended drafts. A pure-draft selection
        // is valid (the user can bulk-discard pending
        // inserts before saving).
        let Some(model) = selection.model() else {
            return;
        };
        let mut snapshot: Vec<(crate::services::change_tracker::RowKey, Vec<Value>)> = Vec::new();
        let mut draft_ids: Vec<u64> = Vec::new();
        let mut had_persisted_row = false;
        let mut unreadable_key_rows = 0usize;
        for pos in &positions {
            let Some(item) = model.item(*pos) else { continue };
            let Ok(row_obj) = item.downcast::<crate::ui::row_object::RowObject>() else {
                continue;
            };
            if let Some(draft_id) = row_obj.draft_id() {
                draft_ids.push(draft_id);
                continue;
            }
            had_persisted_row = true;
            let cells = row_obj.cells_clone();
            if row_key_is_unreadable(&cells, &pk_indices) {
                unreadable_key_rows += 1;
                continue;
            }
            if let Some(pair) = build_persisted_row_key(cells, &pk_indices) {
                snapshot.push(pair);
            }
        }
        // A row whose key the driver could not decode cannot be named in
        // a WHERE clause, so refuse the whole selection rather than
        // deleting part of it without saying so.
        if unreadable_key_rows > 0 {
            let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                title: crate::tr!("Cannot delete"),
                body: crate::tr!(
                    "Some selected rows have a key value this driver could not read, so they cannot be identified. Reload the table, or delete those rows from a SQL editor."
                ),
            });
            return;
        }
        // PK gate only fires when persisted rows are involved.
        // Pure-draft selections sail through to discard.
        if had_persisted_row && pk_indices.is_empty() {
            let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                title: crate::tr!("Cannot delete"),
                body: crate::tr!("This table has no primary key — editing is disabled."),
            });
            return;
        }
        if snapshot.is_empty() && draft_ids.is_empty() {
            return;
        }
        let count = snapshot.len() + draft_ids.len();
        let tab_id = self.tab_id;
        let selection_for_commit = selection.clone();
        let commit_delete = move |snapshot: Vec<(crate::services::change_tracker::RowKey, Vec<Value>)>,
                                  draft_ids: Vec<u64>| {
            crate::services::change_tracker::with_tab(tab_id, |t| {
                for (key, row) in snapshot {
                    t.track_delete(key, row);
                }
                for id in draft_ids {
                    t.discard_draft(id);
                }
            });
            // Clear the multi-row selection so the
            // "{n} selected" badge disappears and the Delete
            // button tooltip resets. Without this the bitset
            // still contains the now-strikethrough rows
            // (they remain in the model until Save). Spreadsheet
            // convention: a bulk action ends the selection it
            // operated on.
            selection_for_commit.unselect_all();
        };
        if count >= BULK_DELETE_CONFIRM_THRESHOLD {
            // Dialog parent is any descendant of the toplevel
            // window — adw::AlertDialog walks up to find the
            // window. The inner_stack is always parented to
            // the BrowseTab's root toolbar, so it resolves
            // correctly while the tab is visible.
            let title = crate::tr!("Delete {n} rows?").replace("{n}", &count.to_string());
            let body = crate::tr!("These rows will be marked for deletion. They aren't removed until you click Save.");
            let dialog = adw::AlertDialog::new(Some(&title), Some(&body));
            dialog.add_response("cancel", &crate::tr!("Cancel"));
            dialog.add_response("delete", &crate::tr!("Delete"));
            dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
            dialog.set_default_response(Some("cancel"));
            dialog.set_close_response("cancel");
            let pending = std::cell::RefCell::new(Some((snapshot, draft_ids)));
            dialog.connect_response(None, move |dlg, response| {
                dlg.close();
                if response == "delete"
                    && let Some((s, d)) = pending.borrow_mut().take()
                {
                    commit_delete(s, d);
                }
            });
            dialog.present(Some(&self.inner_stack));
        } else {
            commit_delete(snapshot, draft_ids);
        }
    }

    pub(super) fn handle_grid_cell_edited(
        &mut self,
        row_position: u32,
        col_index: usize,
        new_value: String,
        row_key: Vec<Value>,
        sender: ComponentSender<Self>,
    ) {
        // A refresh, a sort or a page change replaces the store's rows,
        // so the position the editor opened on can now hold a different
        // row. Committing then writes the new value to a row the user
        // never opened. Compare the primary key captured when editing
        // started with the one at that position now.
        if self.reject_stale_row_edit(row_position, &row_key, &sender) {
            return;
        }
        // Defense in depth: synthetic/queued widget events must obey the same
        // runtime-value gate as rendering, even after a row has been rebound.
        let allowed = self
            .current_columns
            .get(col_index)
            .zip(self.row_object_at(row_position))
            .is_some_and(|(column, row)| crate::ui::grid::cell_allows_inline_edit(column, &row.cell_value(col_index)));
        if !allowed {
            self.refresh_row(row_position);
            return;
        }
        // Cell edits route through the per-tab change tracker
        // so the user can review / Save / Discard a batch.
        //
        // Empty input on a nullable column becomes Value::Null
        // (canonical SQL convention for "user cleared the
        // cell"). Non-empty input is parsed against the
        // column's data_type. SQLite STRICT ANY cells also use
        // their current runtime value kind, since the declaration
        // intentionally permits multiple storage classes.
        //
        // On parse failure the edit is rejected: a toast
        // explains why and `refresh_row` forces a re-bind so
        // the cell goes back to the canonical pre-edit
        // display. The tracker stays untouched so a single
        // bad keystroke can't sneak into the batch.
        //
        // GtkText handles multi-line clipboard paste
        // inconsistently across GTK builds — some embed
        // literal newlines, some strip them silently.
        // Collapse newlines / carriage returns to spaces
        // here so a paste-induced multi-line value never
        // reaches the SQL layer. JSON columns aren't
        // normalised: they need real newlines.
        let normalized = match self
            .current_columns
            .get(col_index)
            .map(|c| classify_type(&c.data_type.to_ascii_lowercase()))
        {
            Some(TypeKind::Json) => new_value,
            _ => normalize_single_line_input(&new_value),
        };
        let col = self.current_columns.get(col_index);
        let row_obj = self.row_object_at(row_position);
        let current_value = row_obj.as_ref().map(|row| row.cell_value(col_index));
        let new = match parse_input_for_grid_cell(&normalized, col, &self.driver_id, current_value.as_ref()) {
            Ok(v) => v,
            Err(message) => {
                let _ = sender.output(BrowseTabOutput::ShowToast(message));
                self.refresh_row(row_position);
                return;
            }
        };
        if let Some(row_obj) = &row_obj
            && let Some(draft_id) = row_obj.draft_id()
        {
            // Draft row — mutate the tracker's draft buffer
            // directly. The RowObject's own cells are also
            // updated so the grid's display reflects the
            // pending value without waiting for re-fetch.
            crate::services::change_tracker::with_tab(self.tab_id, |t| {
                t.track_draft_cell_edit(draft_id, col_index, new.clone());
            });
            row_obj.set_cell(col_index, new);
            return;
        }
        let Some((key, row)) = self.row_key_at(row_position) else {
            self.report_unreadable_row_key(row_position, &sender);
            return;
        };
        let original = row[col_index].clone();
        crate::services::change_tracker::with_tab(self.tab_id, |t| {
            t.track_cell_edit(key, col_index, original, new);
        });
    }

    /// Tell the user why an edit on a row the tracker cannot key was
    /// dropped. Silence here reads as a saved change that never happens.
    fn report_unreadable_row_key(&mut self, row_position: u32, sender: &ComponentSender<Self>) {
        let Some(row_obj) = self.row_object_at(row_position) else {
            return;
        };
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        if !row_key_is_unreadable(&row_obj.cells_clone(), &pk_indices) {
            return;
        }
        let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
            "This row's key could not be read from the database, so the row cannot be changed."
        )));
        self.refresh_row(row_position);
    }

    /// True when the row at `row_position` still carries `expected_key`.
    /// An empty expectation means the grid could not identify the row -
    /// a table with no primary key, where inline editing is already
    /// blocked - so there is nothing to compare and the edit proceeds.
    pub(super) fn row_position_still_holds(&self, row_position: u32, expected_key: &[Value]) -> bool {
        if expected_key.is_empty() {
            return true;
        }
        let Some(row_obj) = self.row_object_at(row_position) else {
            return false;
        };
        if row_obj.draft_id().is_some() {
            return true;
        }
        row_key_matches(&self.current_columns, &row_obj.cells_clone(), expected_key)
    }

    fn reject_stale_row_edit(&mut self, row_position: u32, row_key: &[Value], sender: &ComponentSender<Self>) -> bool {
        if self.row_position_still_holds(row_position, row_key) {
            return false;
        }
        let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
            "That row moved while you were editing. The change was not applied."
        )));
        self.refresh_row(row_position);
        true
    }

    pub(super) fn handle_grid_set_cell_null(
        &mut self,
        row_position: u32,
        col_index: usize,
        row_key: Vec<Value>,
        sender: ComponentSender<Self>,
    ) {
        if self.reject_stale_row_edit(row_position, &row_key, &sender) {
            return;
        }
        let Some((key, row)) = self.row_key_at(row_position) else {
            self.report_unreadable_row_key(row_position, &sender);
            return;
        };
        let original = row[col_index].clone();
        crate::services::change_tracker::with_tab(self.tab_id, |t| {
            t.track_cell_edit(key, col_index, original, Value::Null);
        });
    }

    pub(super) fn handle_grid_delete_row(
        &mut self,
        row_position: u32,
        row_key: Vec<Value>,
        sender: ComponentSender<Self>,
    ) {
        if self.reject_stale_row_edit(row_position, &row_key, &sender) {
            return;
        }
        let Some((key, row)) = self.row_key_at(row_position) else {
            self.report_unreadable_row_key(row_position, &sender);
            return;
        };
        crate::services::change_tracker::with_tab(self.tab_id, |t| {
            t.track_delete(key, row);
        });
    }

    pub(super) fn handle_grid_copy_row_as_insert(&mut self, row_position: u32, sender: ComponentSender<Self>) {
        let _ = sender.output(BrowseTabOutput::CopyRowAsInsert { row_position });
    }

    pub(super) fn handle_grid_copy_to_clipboard(&mut self, text: String, sender: ComponentSender<Self>) {
        let _ = sender.output(BrowseTabOutput::CopyToClipboard(text));
    }

    pub(super) fn handle_copy_selected_rows_as_tsv(&mut self, sender: ComponentSender<Self>) {
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let positions = selected_positions(selection);
        if positions.is_empty() {
            return;
        }
        let model = match selection.model() {
            Some(m) => m,
            None => return,
        };
        let mut rows = Vec::with_capacity(positions.len());
        for pos in &positions {
            let Some(item) = model.item(*pos) else { continue };
            let Ok(row) = item.downcast::<crate::ui::row_object::RowObject>() else {
                continue;
            };
            let Some(cells) = row.complete_cells() else {
                let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                    "Some row values were not fetched. Show hidden columns and reload before copying or exporting."
                )));
                return;
            };
            rows.push(cells);
        }
        if rows.is_empty() {
            return;
        }
        let tsv = tablepro_core::export::render_tsv(&self.current_columns, &rows, false);
        let _ = sender.output(BrowseTabOutput::CopyToClipboard(tsv));
    }

    pub(super) fn handle_paste_not_supported(&mut self, sender: ComponentSender<Self>) {
        let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
            "Pasting rows isn't supported yet"
        )));
    }

    pub(super) fn handle_select_all_rows(&mut self) {
        if let Some(selection) = self.current_selection.as_ref() {
            let n = selection.n_items();
            if n > 0 {
                selection.select_all();
            }
        }
    }

    pub(super) fn handle_go_to_first_row(&mut self) {
        let Some(cv) = self.current_column_view.as_ref() else {
            return;
        };
        let n = self.current_selection.as_ref().map(|s| s.n_items()).unwrap_or(0);
        if n == 0 {
            return;
        }
        cv.scroll_to(
            0,
            None,
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
    }

    pub(super) fn handle_go_to_last_row(&mut self) {
        let Some(cv) = self.current_column_view.as_ref() else {
            return;
        };
        let n = self.current_selection.as_ref().map(|s| s.n_items()).unwrap_or(0);
        if n == 0 {
            return;
        }
        cv.scroll_to(
            n - 1,
            None,
            gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
            None,
        );
    }

    pub(super) fn handle_commit_save(&mut self, sender: ComponentSender<Self>) {
        let columns = self.current_columns.clone();
        let driver_id = self.driver_id.clone();
        let schema = self.schema.clone();
        let table = self.table.clone();
        let result = crate::services::change_tracker::with_tab_ref(self.tab_id, |t| {
            t.materialize(&driver_id, schema.as_deref(), &table, &columns)
        });
        match result {
            Some(Ok((statements, sources))) if !statements.is_empty() => {
                // Disable both buttons for the duration of the
                // in-flight transaction. SaveCompleted /
                // SaveFailed re-enable them. This prevents a
                // double-click firing two transactions and
                // matches GNOME's standard "in-progress action"
                // affordance (busy spinner + disabled control).
                self.save_button.set_sensitive(false);
                self.discard_button.set_sensitive(false);
                // SaveCompleted will refetch the page; capture
                // the focused row's PK now so it can be re-
                // selected after the reload.
                self.capture_focus_for_restore();
                let _ = sender.output(BrowseTabOutput::ExecuteTransaction { statements, sources });
            }
            Some(Ok(_)) => {
                // Nothing to save (tracker empty) — refresh bar.
                self.refresh_pending_bar(0);
            }
            Some(Err(e)) => {
                let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
                    title: crate::tr!("Cannot save"),
                    body: format!("{e}"),
                });
            }
            None => {}
        }
    }

    pub(super) fn handle_discard_all(&mut self, sender: ComponentSender<Self>) {
        crate::services::change_tracker::with_tab(self.tab_id, |t| t.clear());
        self.emit_fetch_page(&sender);
    }

    pub(super) fn handle_pending_count_changed(&mut self, n: usize, sender: ComponentSender<Self>) {
        self.refresh_pending_bar(n);
        // Tell the App so it can prefix the tab title with the
        // GNOME-Text-Editor "•" dot for dirty buffers. Only on
        // real transitions (empty ↔ non-empty) so a count
        // change like 2 → 3 doesn't re-rewrite the tab title.
        let dirty = n > 0;
        if dirty != self.was_dirty.get() {
            self.was_dirty.set(dirty);
            let _ = sender.output(BrowseTabOutput::DirtyChanged(dirty));
        }
        // Note: row re-binds are driven by the parallel
        // ChangedRows event, not from here. PendingCountChanged
        // fires on every tracker mutation so re-binding the
        // viewport here would be wasteful — most edits affect
        // exactly one row and ChangedRows hits only that row.
    }

    pub(super) fn handle_changed_rows(&mut self, keys: Vec<crate::services::change_tracker::RowKey>) {
        // Walk the model once per key. For typical interactive
        // edits (one cell at a time) this is O(n) per keystroke
        // where n = visible row count — bounded and cheap.
        // Bulk operations (Discard) emit one ChangedRows per
        // op via undo unwind, again bounded.
        for key in &keys {
            if let Some(pos) = self.find_row_position_by_key(key) {
                self.refresh_row_at(pos);
            }
        }
    }

    pub(super) fn handle_save_completed(&mut self, sender: ComponentSender<Self>) {
        crate::services::change_tracker::with_tab(self.tab_id, |t| t.clear());
        self.refresh_pending_bar(0);
        self.save_button.set_sensitive(true);
        self.discard_button.set_sensitive(true);
        self.emit_fetch_page_and_count(&sender);
    }

    pub(super) fn handle_save_failed(&mut self, message: String, sender: ComponentSender<Self>) {
        self.save_button.set_sensitive(true);
        self.discard_button.set_sensitive(true);
        let _ = sender.output(BrowseTabOutput::ShowSelectionAlert {
            title: crate::tr!("Save failed"),
            body: message,
        });
    }

    pub(super) fn handle_flash_error_row(&self, source: crate::services::change_tracker::StatementSource) {
        self.flash_error_row(&source);
    }

    pub(super) fn handle_focus_inserted_draft(&self) {
        self.focus_inserted_draft();
    }

    pub(super) fn handle_undo(&mut self) {
        use crate::services::change_tracker::UndoOp;
        let op = match crate::services::change_tracker::with_tab(self.tab_id, |t| t.undo()) {
            Some(Some(op)) => op,
            _ => return,
        };
        match op {
            UndoOp::CellEdit {
                row_key,
                col,
                prev_value,
                ..
            } => {
                // Drafts hold the post-edit value in
                // RowObject.cells (mirrored at edit time);
                // reverting the visible value requires
                // mutating the cell back. Persisted rows
                // never mutate RowObject — the tracker is
                // the single source of truth and
                // connect_bind queries
                // `current_cell_value` to overlay the
                // pending edit. set_cell on a persisted
                // row is a harmless no-op (the cell
                // already holds the original).
                if let Some(pos) = self.find_row_position_by_key(&row_key)
                    && let Some(row_obj) = self.row_object_at(pos)
                {
                    row_obj.set_cell(col, prev_value);
                }
            }
            UndoOp::Insert { draft_id, .. } => {
                // The draft RowObject is still in the
                // ListStore (prepended by InsertRow). Walk
                // the store, find the row whose draft_id
                // matches, remove it. The subsequent
                // ChangedRows event for `Draft(id)` is a
                // no-op once the row is gone.
                if let Some(store) = self.list_store() {
                    let n = store.n_items();
                    for i in 0..n {
                        if let Some(obj) = store.item(i)
                            && let Ok(row) = obj.downcast::<crate::ui::row_object::RowObject>()
                            && row.draft_id() == Some(draft_id)
                        {
                            store.remove(i);
                            break;
                        }
                    }
                }
            }
            UndoOp::Delete { row_key, .. } => {
                // No RowObject mutation needed — the row was
                // never visually removed; it stayed in the
                // ListStore with a strikethrough overlay
                // applied at bind time. The tracker's
                // emit_changed → items_changed re-bind drops
                // the strikethrough automatically because
                // `row_state` returns Clean once the deletes
                // entry is gone.
                let _ = row_key;
            }
        }
    }

    pub(super) fn handle_redo(&mut self) {
        use crate::services::change_tracker::UndoOp;
        let op = match crate::services::change_tracker::with_tab(self.tab_id, |t| t.redo()) {
            Some(Some(op)) => op,
            _ => return,
        };
        match op {
            UndoOp::CellEdit {
                row_key,
                col,
                new_value,
                ..
            } => {
                if let Some(pos) = self.find_row_position_by_key(&row_key)
                    && let Some(row_obj) = self.row_object_at(pos)
                {
                    row_obj.set_cell(col, new_value);
                }
            }
            UndoOp::Insert { draft_id, values } => {
                // Re-add the draft RowObject. Match the
                // original insert path: prepend at position 0.
                if let Some(store) = self.list_store() {
                    let draft_row = crate::ui::row_object::RowObject::new_draft(draft_id, values);
                    store.insert(0, &draft_row);
                }
            }
            UndoOp::Delete { .. } => {}
        }
    }
}

/// Build the draft values for a duplicated row. Columns whose value is
/// owned by the database (primary key, identity / serial, generated) are
/// blanked. A row containing an undecodable cell or whose value count does
/// not match the columns is refused: carrying it into an INSERT could bind
/// the unreadable value as NULL without the user seeing or correcting it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum DuplicateRowError {
    CellCountMismatch { expected: usize, actual: usize },
    Undecodable { column: String },
}

fn duplicate_row_values(columns: &[ColumnInfo], source_cells: &[Value]) -> Result<Vec<Value>, DuplicateRowError> {
    if source_cells.len() != columns.len() {
        return Err(DuplicateRowError::CellCountMismatch {
            expected: columns.len(),
            actual: source_cells.len(),
        });
    }
    columns
        .iter()
        .enumerate()
        .map(|(i, col)| {
            if col.primary_key || col.is_auto_increment || col.is_generated {
                return Ok(Value::Null);
            }
            match &source_cells[i] {
                Value::Undecodable(_) => Err(DuplicateRowError::Undecodable {
                    column: col.name.clone(),
                }),
                value => Ok(value.clone()),
            }
        })
        .collect()
}

/// Compare the primary-key values a row carries now with the ones read
/// when its editor opened.
fn row_key_matches(columns: &[ColumnInfo], cells: &[Value], expected: &[Value]) -> bool {
    if expected.is_empty() {
        return true;
    }
    let mut current = columns
        .iter()
        .enumerate()
        .filter(|(_, column)| column.primary_key)
        .map(|(index, _)| cells.get(index));
    let mut wanted = expected.iter();
    loop {
        match (current.next(), wanted.next()) {
            (None, None) => return true,
            (Some(Some(value)), Some(want)) if value == want => continue,
            _ => return false,
        }
    }
}

#[cfg(test)]
mod row_identity_tests {
    use super::{DuplicateRowError, duplicate_row_values, row_key_matches};
    use tablepro_core::{ColumnInfo, Value};

    fn column(name: &str, primary_key: bool) -> ColumnInfo {
        ColumnInfo {
            name: name.into(),
            data_type: "integer".into(),
            nullable: false,
            primary_key,
            is_auto_increment: false,
            default_value: None,
            is_generated: false,
            comment: None,
            collation: None,
            enum_type: None,
            domain_type: None,
        }
    }

    #[test]
    fn the_same_row_still_matches_its_key() {
        let columns = [column("id", true), column("note", false)];
        let cells = [Value::Int(7), Value::Text("a".into())];
        assert!(row_key_matches(&columns, &cells, &[Value::Int(7)]));
    }

    #[test]
    fn a_different_row_at_the_same_position_is_refused() {
        let columns = [column("id", true), column("note", false)];
        let cells = [Value::Int(8), Value::Text("a".into())];
        assert!(!row_key_matches(&columns, &cells, &[Value::Int(7)]));
    }

    #[test]
    fn editing_another_column_of_the_same_row_still_matches() {
        let columns = [column("id", true), column("note", false)];
        let cells = [Value::Int(7), Value::Text("edited".into())];
        assert!(row_key_matches(&columns, &cells, &[Value::Int(7)]));
    }

    #[test]
    fn every_component_of_a_composite_key_has_to_match() {
        let columns = [column("a", true), column("b", true), column("c", false)];
        assert!(row_key_matches(
            &columns,
            &[Value::Int(1), Value::Int(2), Value::Int(9)],
            &[Value::Int(1), Value::Int(2)]
        ));
        assert!(!row_key_matches(
            &columns,
            &[Value::Int(1), Value::Int(3), Value::Int(9)],
            &[Value::Int(1), Value::Int(2)]
        ));
    }

    #[test]
    fn a_key_that_lost_or_gained_a_component_is_refused() {
        let columns = [column("a", true), column("b", true)];
        assert!(!row_key_matches(
            &columns,
            &[Value::Int(1), Value::Int(2)],
            &[Value::Int(1)]
        ));
        let one_key = [column("a", true), column("b", false)];
        assert!(!row_key_matches(
            &one_key,
            &[Value::Int(1), Value::Int(2)],
            &[Value::Int(1), Value::Int(2)]
        ));
    }

    #[test]
    fn a_null_key_component_compares_by_value_like_any_other() {
        let columns = [column("a", true), column("b", false)];
        assert!(row_key_matches(&columns, &[Value::Null, Value::Int(1)], &[Value::Null]));
        assert!(!row_key_matches(
            &columns,
            &[Value::Int(0), Value::Int(1)],
            &[Value::Null]
        ));
    }

    #[test]
    fn a_table_without_a_primary_key_has_nothing_to_compare() {
        let columns = [column("a", false)];
        assert!(row_key_matches(&columns, &[Value::Int(1)], &[]));
    }

    #[test]
    fn duplicating_a_row_blanks_database_owned_cells_and_preserves_exact_values() {
        let columns = [column("id", true), column("amount", false), column("note", false)];
        let source = [
            Value::Int(7),
            Value::Decimal("12.30".parse().unwrap()),
            Value::Text("keep me".into()),
        ];
        assert_eq!(
            duplicate_row_values(&columns, &source),
            Ok(vec![
                Value::Null,
                Value::Decimal("12.30".parse().unwrap()),
                Value::Text("keep me".into())
            ])
        );
    }

    #[test]
    fn duplicating_a_row_refuses_an_undecodable_cell_instead_of_turning_it_into_null() {
        let columns = [column("id", true), column("amount", false)];
        let source = [Value::Int(7), Value::Undecodable("NUMERIC".into())];
        assert_eq!(
            duplicate_row_values(&columns, &source),
            Err(DuplicateRowError::Undecodable {
                column: "amount".into()
            })
        );
    }

    #[test]
    fn duplicating_a_row_carries_the_full_long_text_into_the_insert_not_the_display_text() {
        let long_text = "é".repeat(250_000);
        let long_utf8_bytes = "z".repeat(90_000).into_bytes();
        let columns = [column("id", true), column("body", false), column("raw", false)];
        let source = [
            Value::Int(1),
            Value::Text(long_text.clone()),
            Value::Bytes(long_utf8_bytes.clone()),
        ];
        assert_ne!(
            crate::ui::grid::value_to_display_text(&source[1]),
            long_text,
            "the value must be long enough for the grid to truncate it"
        );

        let values = duplicate_row_values(&columns, &source).unwrap();
        assert_eq!(values[1], Value::Text(long_text.clone()));
        assert_eq!(values[2], Value::Bytes(long_utf8_bytes.clone()));

        let mut tracker = crate::services::change_tracker::TabChangeTracker::new();
        tracker.track_insert(values);
        let (statements, _) = tracker.materialize("mysql", None, "t", &columns).unwrap();
        assert_eq!(
            statements[0].1,
            vec![Value::Null, Value::Text(long_text), Value::Bytes(long_utf8_bytes)]
        );
    }

    #[test]
    fn duplicating_a_row_refuses_a_source_with_wrong_cell_count() {
        let columns = [column("id", true), column("note", false)];
        for source in [
            &[Value::Int(1)][..],
            &[Value::Int(1), Value::Text("ok".into()), Value::Int(3)][..],
        ] {
            let actual = source.len();
            assert_eq!(
                duplicate_row_values(&columns, source),
                Err(DuplicateRowError::CellCountMismatch { expected: 2, actual })
            );
        }
    }

    #[test]
    fn a_row_shorter_than_its_columns_is_refused_rather_than_assumed_equal() {
        let columns = [column("a", true), column("b", true)];
        assert!(!row_key_matches(
            &columns,
            &[Value::Int(1)],
            &[Value::Int(1), Value::Int(2)]
        ));
    }
}
