use relm4::gtk::glib;
use relm4::{ComponentSender, gtk};

use tablepro_core::QueryResult;

use super::*;

pub(super) fn column_layout_matches(rendered: &[ColumnInfo], current: &[ColumnInfo]) -> bool {
    rendered == current
}

impl BrowseTab {
    pub(super) fn list_store(&self) -> Option<crate::ui::row_store::RowStore> {
        let selection = self.current_selection.as_ref()?;
        selection.model()?.downcast::<crate::ui::row_store::RowStore>().ok()
    }

    /// Notify the chain (ListStore → SelectionModel → ColumnView) that
    /// the row at `pos` has changed so the view rebinds its cells.
    ///
    /// Why: per GTK4 docs, `items-changed` "should never be emitted
    /// directly by users of the model". Splicing a fresh RowObject
    /// into the underlying `gio::ListStore` is the canonical way to
    /// force the downstream chain to invalidate caches and rebind.
    pub(super) fn refresh_row_at(&self, pos: u32) {
        let row_obj = self.row_object_at(pos);
        let store = self.list_store();
        let store_pos = match (row_obj.as_ref(), store.as_ref()) {
            (Some(r), Some(s)) => s.find(r),
            _ => None,
        };
        // ColumnView's list-item-manager keeps a per-listitem
        // cached pointer to the model item it's currently bound
        // to. When it receives items-changed for a position, it
        // re-fetches the model item at that position and
        // **compares pointers**: if same identity, it skips
        // unbind/bind because the bound item "didn't actually
        // change". Mutating cells *inside* the existing
        // RowObject (which is what set_cell does) keeps the
        // pointer constant — that's why neither plain
        // `items_changed` nor `splice(pos, 1, &[same_row_obj])`
        // forces a rebind here.
        //
        // The fix: substitute a freshly-allocated RowObject
        // carrying the post-mutation cells. Different GObject
        // identity → list-item-manager invalidates the cache,
        // unbinds the old listitem widget, rebinds with the
        // new item, connect_bind fires, label.set_text picks up
        // the reverted value. Atomic via splice: one items-
        // changed emission, no flicker, no scroll jump.
        if let (Some(store), Some(store_pos), Some(old)) = (store, store_pos, row_obj) {
            let replacement = old.clone_preserving_loading_state();
            store.splice(store_pos, 1, &[replacement]);
        }
    }

    /// Look up the live `RowObject` at a selection-model position.
    /// Used to detect whether a row is a draft (`draft_id().is_some()`)
    /// vs a persisted row, and to mutate draft cells in place when
    /// the user types into them.
    pub(super) fn row_object_at(&self, position: u32) -> Option<crate::ui::row_object::RowObject> {
        let model = self.current_selection.as_ref()?.model()?;
        model
            .item(position)?
            .downcast::<crate::ui::row_object::RowObject>()
            .ok()
    }

    /// Locate the row in the current model that matches a given
    /// `RowKey`. Drafts match by `draft_id`; persisted rows match by
    /// recomputing the row's PK key-tuple from cell values and
    /// comparing. Returns the position in the (filtered) selection
    /// model, or `None` if the row isn't on the current page.
    pub(super) fn capture_focus_for_restore(&self) {
        use crate::services::change_tracker::RowKey;
        // If a previous capture is still pending (sort+save fire in
        // quick succession before the first reload's restore runs), keep
        // the original capture. The first user-visible focus should
        // anchor to where they were before triggering the chain — not
        // wherever focus drifted mid-rebuild.
        if self.pending_focus_restore.borrow().is_some() {
            return;
        }
        let Some(selection) = self.current_selection.as_ref() else {
            return;
        };
        let bitset = selection.selection();
        if bitset.size() == 0 {
            return;
        }
        let pos = bitset.nth(0);
        let Some(model) = selection.model() else { return };
        let Some(item) = model.item(pos) else { return };
        let Ok(row) = item.downcast::<crate::ui::row_object::RowObject>() else {
            return;
        };
        let key = if let Some(draft_id) = row.draft_id() {
            Some(RowKey::Draft(draft_id))
        } else {
            let pk_indices: Vec<usize> = self
                .current_columns
                .iter()
                .enumerate()
                .filter(|(_, c)| c.primary_key)
                .map(|(i, _)| i)
                .collect();
            if pk_indices.is_empty() {
                None
            } else {
                let pk_values: Vec<Value> = pk_indices.iter().map(|&i| row.cell_value(i)).collect();
                RowKey::from_pk_values(&pk_values)
            }
        };
        *self.pending_focus_restore.borrow_mut() = key;
    }

    /// Grab focus + start-editing on the freshly-inserted draft row's
    /// Scroll + focus + select the freshly-prepended draft row, then
    /// open its first editable cell for input. Called via
    /// `BrowseTabInput::FocusInsertedDraft` rather than directly so we
    /// read the current `column_view` / `selection` state rather than
    /// a captured-by-value reference that could go stale if a
    /// RowsLoaded fires between Insert and the deferred focus. The
    /// whole sequence is queued via `idle_add_local_once` so the
    /// inner-stack flip (empty → grid) has time to allocate the
    /// ScrolledWindow's adjustments before `cv.scroll_to(...)` runs.
    pub(super) fn focus_inserted_draft(&self) {
        let Some(cv) = self.current_column_view.clone() else {
            return;
        };
        let selection = self.current_selection.clone();
        glib::idle_add_local_once(move || {
            // At idle time the column-view may already be detached
            // (rare race, e.g. user pressed F5 between InsertRow and
            // this idle). Bail silently — the row was inserted; only
            // the auto-edit affordance is missed.
            if cv.root().is_none() {
                return;
            }
            // New drafts always land at position 0 (prepended).
            if let Some(sel) = selection.as_ref() {
                sel.select_item(0, true);
            }
            cv.scroll_to(
                0,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
            let Some(window) = cv.root().and_then(|r| r.dynamic_cast::<gtk::Window>().ok()) else {
                return;
            };
            let Some(focused) = gtk::prelude::GtkWindowExt::focus(&window) else {
                return;
            };
            if let Ok(label) = focused.dynamic_cast::<crate::ui::cell_editor::CellEditor>() {
                crate::ui::grid::enter_cell_edit_mode(&label);
            }
            // Bool draft (CheckButton focused) needs no edit-mode
            // dance; clicking / Space toggles natively.
        });
    }

    /// Re-select and scroll-to the row captured by
    /// `capture_focus_for_restore`, if it's still on the page after
    /// the reload. Silently no-ops if the row was filtered out, sorted
    /// to a different page, or removed by the commit. Always clears
    /// the captured key so it doesn't bleed into the next reload.
    pub(super) fn restore_focused_row(&self) {
        let Some(key) = self.pending_focus_restore.borrow_mut().take() else {
            return;
        };
        let Some(position) = self.find_row_position_by_key(&key) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(position, None, gtk::ListScrollFlags::FOCUS, None);
        }
    }

    /// Build the `ColumnView` if we have both the schema (`current_columns`,
    /// from `ColumnsLoaded`) and the current page's data (`current_result`,
    /// from `RowsLoaded`). Until both are present the `inner_stack` stays
    /// on the "loading" status page so the user can't interact with cells
    /// whose editability map is wrong.
    pub(super) fn render_grid_if_ready(&mut self, sender: ComponentSender<Self>) {
        let Some(result) = self.current_result.clone() else {
            return;
        };
        if self.current_columns.is_empty() {
            // Schema not yet loaded — keep the loading status visible.
            // ColumnsLoaded will re-invoke this when it arrives.
            return;
        }

        // Fast path: column structure hasn't changed since the last
        // render (typical for sort flips / page changes / save reloads
        // within one tab). Reuse the existing `ColumnView` and only
        // refresh the underlying `ListStore`. Saves O(N×M) factory
        // recreations and selection rebuilds per page change.
        if self.column_view_matches_current_columns()
            && let Some(store) = self.list_store()
        {
            if !self.refresh_grid_data(&result, &store) {
                self.show_projection_error();
                return;
            }
            self.refresh_grid_chrome(&result);
            self.restore_focused_row();
            let _ = sender.output(BrowseTabOutput::StateChanged);
            return;
        }

        // Cold path: first render for this tab, or column structure
        // changed (rare in practice — would require schema migration
        // mid-session). Build the full column-view scaffolding.
        clear_box(&self.grid_holder);
        let edit_sender = if self.read_only {
            None
        } else {
            Some(self.grid_sender.clone())
        };
        let pk_col_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        let foreign_key_columns = self
            .foreign_keys
            .iter()
            .flat_map(|fk| fk.columns.iter().cloned())
            .collect();
        let tab_ctx = TabGridContext {
            tab_id: Some(self.tab_id),
            pk_col_indices,
            projected_columns: self.current_projection.clone(),
            preview_long_values: self.driver_id != "redis",
            preview_redis_strings: self.driver_id == "redis",
            preview_result_values: false,
            foreign_key_columns,
        };
        let (column_view, selection) = build_column_view(
            &result,
            &self.current_columns,
            &self.table,
            edit_sender,
            Some(self.grid_sender.clone()),
            self.current_sort,
            Some(self.grid_sender.clone()),
            self.connection_id,
            tab_ctx,
            self.persistence.column_widths.clone(),
            self.database.clone(),
        );
        self.current_selection = Some(selection);
        self.current_column_view = Some(column_view.clone());
        self.rendered_columns.clone_from(&self.current_columns);

        // Selection-changed signal updates the count badge and the
        // Delete button's tooltip live. The new MultiSelection is a
        // fresh instance per rebuild, so the previous binding (if
        // any) drops with the old selection — no leak.
        let selection_label_for_signal = self.selection_label.clone();
        if let Some(sel) = self.current_selection.as_ref() {
            let inspector = self.inspector.clone();
            let columns = self.current_columns.clone();
            sel.connect_selection_changed(move |sel, _, _| {
                let n = sel.selection().size() as u32;
                let tooltip = selection_tooltip(sel, &columns);
                update_selection_chrome(&selection_label_for_signal, n, tooltip.as_deref());
                inspector.show_row(inspected_row(sel, &columns));
            });
            // Page rebuild clears MultiSelection's bitset; reset the
            // chrome explicitly so a stale "5 selected" doesn't linger.
            update_selection_chrome(&self.selection_label, 0, None);
        }

        // Re-prepend any pending draft rows so they survive page changes,
        // sort flips, and F5 refresh. The tracker is the canonical source
        // of truth for drafts; the grid model is rebuilt fresh on every
        // RowsLoaded so without this step the drafts vanish visually
        // while the tracker still holds them, leading to confused state.
        self.reprepend_drafts();

        let scrolled = gtk::ScrolledWindow::builder()
            .child(&column_view)
            .hexpand(true)
            .vexpand(true)
            .build();
        self.grid_holder.append(&scrolled);
        self.refresh_grid_chrome(&result);
        self.restore_focused_row();
        let _ = sender.output(BrowseTabOutput::StateChanged);
    }

    /// True when the cached `ColumnView` uses the current column metadata.
    /// A type or editability change requires new factories even if the count
    /// stays fixed.
    pub(super) fn column_view_matches_current_columns(&self) -> bool {
        self.current_column_view.is_some() && column_layout_matches(&self.rendered_columns, &self.current_columns)
    }

    /// Replace the rows in the existing `ListStore` without touching
    /// the columns / factories / selection model. Drafts are
    /// re-prepended so they survive the swap.
    pub(super) fn refresh_grid_data(
        &self,
        result: &std::sync::Arc<QueryResult>,
        store: &crate::ui::row_store::RowStore,
    ) -> bool {
        let key_indices = self
            .current_columns
            .iter()
            .enumerate()
            .filter_map(|(index, column)| column.primary_key.then_some(index))
            .collect();
        if let Some(indices) = &self.current_projection {
            let replaced = if self.driver_id == "redis" {
                store.replace_projected_with_redis_string_previews(
                    result.clone(),
                    indices.clone(),
                    self.current_columns.len(),
                    key_indices,
                )
            } else {
                store.replace_projected_with_previews(
                    result.clone(),
                    indices.clone(),
                    self.current_columns.len(),
                    key_indices,
                )
            };
            if let Err(error) = replaced {
                tracing::error!(%error, "projected browse refresh does not match the table schema");
                store.replace_shared(std::sync::Arc::new(QueryResult {
                    columns: self.current_columns.clone(),
                    rows: Vec::new(),
                    truncated: false,
                }));
                return false;
            }
        } else {
            if self.driver_id == "redis" {
                store.replace_shared_with_redis_string_previews(result.clone(), key_indices);
            } else {
                store.replace_shared_with_previews(result.clone(), key_indices);
            }
        }
        self.reprepend_drafts();
        true
    }

    pub(super) fn show_projection_error(&self) {
        self.show_error_inner(&crate::tr!(
            "The database returned rows that do not match the table columns."
        ));
        self.inner_stack.set_visible_child_name("error");
    }

    /// Update paginator label, button sensitivity, and stack child —
    /// chrome that depends on the result but not the column structure.
    pub(super) fn refresh_grid_chrome(&self, result: &QueryResult) {
        self.refresh_crud_buttons();
        self.update_paginator_label();
        let on_first_page = self.current_offset == 0;
        self.first_button.set_sensitive(!on_first_page);
        self.prev_button.set_sensitive(!on_first_page);
        let n_rows = result.rows.len() as u64;
        self.next_button.set_sensitive(n_rows == self.page_size);
        // Last only enables when we know the total AND we aren't
        // already there. Without a known total, the button stays
        // disabled — matches `RowCountLoaded`-gated UX everywhere
        // else.
        let last_target = self
            .current_total_rows
            .filter(|t| *t > 0)
            .map(|t| (t - 1) / self.page_size * self.page_size);
        self.last_button
            .set_sensitive(last_target.is_some_and(|target| self.current_offset != target));

        self.refresh_inner_stack_visibility();
        self.suppress_combo_emit.set(false);
    }

    /// Switch the inner stack to the grid once the first page has
    /// loaded. Previously this helper also flipped to a dedicated
    /// "empty" AdwStatusPage when there were 0 rows + 0 drafts on
    /// page 0 — but that pattern triggered a GtkListBase bounds
    /// invariant violation when the user then inserted a draft and
    /// the stack crossfaded back to "grid": the GtkColumnView's
    /// adjustments hadn't been allocated yet because the view was
    /// the hidden stack child during the empty interlude, and the
    /// first scroll / select call against it aborted with
    /// `gtk_list_base_update_adjustments: bounds.y == 0`.
    ///
    /// GNOME Files / Builder don't show a status page for empty
    /// lists either — they just render an empty list with column
    /// headers. Mirror that: once the grid is built, stay on it
    /// regardless of row count. The "Press Ctrl+N to add the first
    /// row" hint moves into the column view's empty body (handled
    /// natively by GtkColumnView's empty-area rendering).
    pub(super) fn refresh_inner_stack_visibility(&self) {
        if self.current_result.is_some() {
            self.inner_stack.set_visible_child_name("grid");
        }
    }

    /// Walk `tracker.drafts()` and prepend each as a draft `RowObject`
    /// at the top of the grid's `ListStore`. Forward iteration with
    /// `insert(0, …)` preserves the original insertion order: newest
    /// at the top, then older drafts beneath, then persisted rows.
    pub(super) fn reprepend_drafts(&self) {
        let Some(store) = self.list_store() else {
            return;
        };
        let drafts = crate::services::change_tracker::with_tab_ref(self.tab_id, |t| {
            t.drafts()
                .iter()
                .map(|d| (d.draft_id, d.values.clone()))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
        for (draft_id, values) in drafts {
            let draft_row = crate::ui::row_object::RowObject::new_draft(draft_id, values);
            store.insert(0, &draft_row);
        }
    }

    /// Force a single-row re-bind. Used when rejecting an invalid
    /// cell edit: the `CellEditor` still holds the user's typed text
    /// after editing-notify fires, so we trigger a re-bind to restore
    /// the canonical display from `RowObject.cell_value()` (which we
    /// did NOT mutate because the parse failed).
    pub(super) fn refresh_row(&self, position: u32) {
        self.refresh_row_at(position);
    }
}

fn inspected_row(
    selection: &gtk::MultiSelection,
    columns: &[ColumnInfo],
) -> Option<Vec<crate::ui::row_inspector::InspectorField>> {
    let bits = selection.selection();
    if bits.size() != 1 {
        return None;
    }
    let row = selection
        .model()?
        .item(bits.nth(0))?
        .downcast::<crate::ui::row_object::RowObject>()
        .ok()?;
    Some(crate::ui::row_inspector::inspector_fields_for_row(columns, &row))
}

fn selection_tooltip(selection: &gtk::MultiSelection, columns: &[ColumnInfo]) -> Option<String> {
    let model = selection.model()?;
    let bits = selection.selection();
    let rows: Vec<Vec<tablepro_core::Value>> = (0..bits.size())
        .filter_map(|i| {
            let row = model
                .item(bits.nth(i as u32))?
                .downcast::<crate::ui::row_object::RowObject>()
                .ok()?;
            Some(row.with_cells(|cells| cells.to_vec()))
        })
        .collect();
    let stats = super::selection::stats::column_stats(columns, &rows);
    Some(super::selection::stats::tooltip(&stats))
}
