pub(in crate::ui::browse_tab) mod stats;

use relm4::gtk;
use relm4::gtk::glib;

use tablepro_core::Value;

use super::*;

impl BrowseTab {
    pub(super) fn find_row_position_by_key(&self, key: &crate::services::change_tracker::RowKey) -> Option<u32> {
        use crate::services::change_tracker::{KeyValue, RowKey};
        let selection = self.current_selection.as_ref()?;
        let model = selection.model()?;
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        let n_items = model.n_items();
        for i in 0..n_items {
            let Some(item) = model.item(i) else { continue };
            let Ok(row) = item.downcast::<crate::ui::row_object::RowObject>() else {
                continue;
            };
            let matched = match key {
                RowKey::Draft(id) => row.draft_id() == Some(*id),
                RowKey::Persisted(target_keys) => {
                    if row.draft_id().is_some() || pk_indices.is_empty() {
                        false
                    } else {
                        let row_keys: Vec<KeyValue> = pk_indices
                            .iter()
                            .map(|&col_idx| (&row.cell_value(col_idx)).into())
                            .collect();
                        row_keys == *target_keys
                    }
                }
            };
            if matched {
                return Some(i);
            }
        }
        None
    }

    /// Locate the row that produced a failing statement and scroll-and-
    /// select it, plus apply a one-shot red flash animation. The flash
    /// state lives on `TabChangeTracker.error_row` so the grid bind
    /// callback picks it up via the existing tracker query path; a
    /// 1.8s timeout clears the state afterwards (matches the CSS
    /// animation duration). Best-effort lookup: a row that's been
    /// paginated past, sorted away, or filtered out won't be found,
    /// and we silently fall through to just the alert dialog.
    pub(super) fn flash_error_row(&self, source: &crate::services::change_tracker::StatementSource) {
        use crate::services::change_tracker::{RowKey, StatementSource};
        let key = match source {
            StatementSource::Insert { draft_id } => RowKey::Draft(*draft_id),
            StatementSource::Update { row_key } | StatementSource::Delete { row_key } => row_key.clone(),
        };
        let Some(position) = self.find_row_position_by_key(&key) else {
            return;
        };
        if let Some(selection) = self.current_selection.as_ref() {
            selection.select_item(position, true);
        }
        if let Some(cv) = self.current_column_view.as_ref() {
            cv.scroll_to(
                position,
                None,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        }
        // Mark the row as the error row and trigger a re-bind so the
        // bind callback applies tp-row-leftmost-error-flash. Schedule
        // a timeout to clear the state once the animation has played.
        // The generation counter protects against a second flash that
        // starts inside the 1.8s window: the older timer's clear runs
        // but no-ops because gen no longer matches.
        let tab_id = self.tab_id;
        let generation =
            crate::services::change_tracker::with_tab(tab_id, |t| t.set_error_row(key.clone())).unwrap_or(0);
        self.refresh_row_at(position);
        let selection_for_clear = self.current_selection.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(1800), move || {
            let cleared = crate::services::change_tracker::with_tab(tab_id, |t| {
                let was_match = t.is_error_row_gen(generation);
                t.clear_error_row_if_gen(generation);
                was_match
            })
            .unwrap_or(false);
            if !cleared {
                // A newer flash superseded ours; don't disturb its bind.
                return;
            }
            // Inline the underlying-store hop because `self` is gone
            // from the closure scope (it's a 1.8s deferred timer);
            // the chain walk is the same as `refresh_row_at`.
            if let Some(selection) = selection_for_clear
                && let Some(model) = selection.model()
                && let Some(row_obj) = model
                    .item(position)
                    .and_then(|o| o.downcast::<crate::ui::row_object::RowObject>().ok())
                && let Some(store) = model.downcast::<crate::ui::row_store::RowStore>().ok()
                && let Some(store_pos) = store.find(&row_obj)
            {
                store.items_changed(store_pos, 1, 1);
            }
        });
    }

    pub(super) fn row_key_at(
        &self,
        row_position: u32,
    ) -> Option<(crate::services::change_tracker::RowKey, Vec<Value>)> {
        let row_obj = self.row_object_at(row_position)?;
        if row_obj.draft_id().is_some() {
            return None;
        }
        let pk_indices: Vec<usize> = self
            .current_columns
            .iter()
            .enumerate()
            .filter(|(_, c)| c.primary_key)
            .map(|(i, _)| i)
            .collect();
        build_persisted_row_key(row_obj.cells_clone(), &pk_indices)
    }

    /// Returns true when the loaded columns include at least one PK.
    /// Used to gate Insert / Delete and reveal the no-PK banner.
    pub(super) fn has_primary_key(&self) -> bool {
        self.current_columns.iter().any(|c| c.primary_key)
    }
}

/// Build a `(RowKey, cells)` pair for a persisted row given its full
/// cell slice and the table's PK column indices. Returns `None` when
/// pk_indices is empty (no PK), any index is out of range, or
/// `RowKey::from_pk_values` rejects the values.
///
/// Pure function so it stays unit-testable without spinning up GTK
/// / RowObject. Callers feed it a clone of the row's cells (already
/// pulled from the model in selection-model space, see the
/// row-position-vs-result-rows note in `DeleteSelectedRow`).
pub(super) fn build_persisted_row_key(
    cells: Vec<Value>,
    pk_indices: &[usize],
) -> Option<(crate::services::change_tracker::RowKey, Vec<Value>)> {
    let pk_values = pk_values_of(&cells, pk_indices)?;
    let key = crate::services::change_tracker::RowKey::from_pk_values(&pk_values)?;
    Some((key, cells))
}

/// Pull the primary-key components out of a row's cells, or `None` when
/// an index runs past the row (a column dropped since the page loaded).
pub(super) fn pk_values_of(cells: &[Value], pk_indices: &[usize]) -> Option<Vec<Value>> {
    pk_indices.iter().map(|&i| cells.get(i).cloned()).collect()
}

/// True when the row at `pk_indices` carries a key the driver could not
/// decode, so it cannot be identified or written back.
pub(super) fn row_key_is_unreadable(cells: &[Value], pk_indices: &[usize]) -> bool {
    pk_values_of(cells, pk_indices)
        .as_deref()
        .is_some_and(crate::services::change_tracker::pk_values_are_unreadable)
}

/// Update the selection-count badge in response to a
/// `MultiSelection` change. Hidden when 0–1 rows are selected
/// (single-row state has no scaling text need); shows
/// "{n} selected · press Delete to remove" once the user
/// multi-selects so the affordance stays discoverable now that
/// the toolbar Delete button is gone (right-click + Delete key
/// are the action surface).
pub(super) fn update_selection_chrome(label: &gtk::Label, n: u32, stats_tooltip: Option<&str>) {
    if n <= 1 {
        label.set_visible(false);
        return;
    }
    let count = n.to_string();
    label.set_label(&crate::tr!("{n} selected · press Delete to remove").replace("{n}", &count));
    label.set_tooltip_text(stats_tooltip.filter(|text| !text.is_empty()));
    label.set_visible(true);
}

pub(super) fn selected_positions(selection: &gtk::MultiSelection) -> Vec<u32> {
    let bitset = selection.selection();
    let mut out = Vec::with_capacity(bitset.size() as usize);
    for i in 0..bitset.size() {
        out.push(bitset.nth(i as u32));
    }
    out.sort_unstable();
    out
}

#[cfg(test)]
mod tests {
    use super::{build_persisted_row_key, row_key_is_unreadable};
    use crate::services::change_tracker::RowKey;
    use tablepro_core::Value;

    #[test]
    pub(super) fn build_pk_single_column() {
        let cells = vec![Value::Int(42), Value::Text("alice".into())];
        let (key, returned) = build_persisted_row_key(cells.clone(), &[0]).expect("valid PK");
        assert!(matches!(key, RowKey::Persisted(_)));
        assert_eq!(returned, cells);
    }

    #[test]
    pub(super) fn build_pk_multi_column_preserves_index_order() {
        // Composite PK formed from columns 2 and 0, in that order.
        // The helper must preserve `pk_indices` ordering so two
        // tables with the same columns in different orders never
        // produce key-collisions on rows that aren't actually equal.
        let cells = vec![
            Value::Text("eu-west".into()),
            Value::Text("ignored".into()),
            Value::Int(7),
        ];
        let (key, _) = build_persisted_row_key(cells, &[2, 0]).expect("composite PK");
        let RowKey::Persisted(kv) = key else {
            panic!("expected Persisted")
        };
        // First component is column-2 (Int 7), second is column-0
        // (Text "eu-west"). Reversed order would be the bug.
        assert_eq!(kv.len(), 2);
    }

    #[test]
    pub(super) fn build_pk_empty_indices_returns_none() {
        // Tables with no PK can't have stable row identity. The
        // caller is expected to short-circuit before reaching the
        // helper, but defending here means the helper is safe to
        // call from any context.
        let cells = vec![Value::Int(1)];
        assert!(build_persisted_row_key(cells, &[]).is_none());
    }

    #[test]
    pub(super) fn build_pk_index_out_of_range_returns_none() {
        // PK index 5 against a 2-cell row was the actual bug class
        // we just fixed — the previous code would index past the
        // end of `result.rows[pos]` when drafts shifted positions.
        // The helper now returns None instead of panicking.
        let cells = vec![Value::Int(1), Value::Text("x".into())];
        assert!(build_persisted_row_key(cells, &[5]).is_none());
    }

    #[test]
    pub(super) fn build_pk_partial_out_of_range_returns_none() {
        // Composite PK where one index is valid and one isn't —
        // any out-of-range component invalidates the whole key.
        let cells = vec![Value::Int(1)];
        assert!(build_persisted_row_key(cells, &[0, 1]).is_none());
    }

    #[test]
    pub(super) fn build_pk_with_null_components_is_allowed() {
        // SQL allows NULL in primary keys for some drivers (rare
        // but legal in SQLite, MySQL with NULL columns, etc.).
        // The tracker's KeyValue::Null mirror handles equality, so
        // the helper must not reject Null PK components — only
        // out-of-range or empty pk_indices fail.
        let cells = vec![Value::Null, Value::Text("x".into())];
        let (key, _) = build_persisted_row_key(cells, &[0]).expect("Null PK is valid");
        assert!(matches!(key, RowKey::Persisted(_)));
    }

    #[test]
    fn a_row_whose_key_could_not_be_decoded_yields_no_key() {
        let cells = vec![Value::Undecodable("NUMERIC".into()), Value::Text("alice".into())];
        assert!(build_persisted_row_key(cells.clone(), &[0]).is_none());
        assert!(row_key_is_unreadable(&cells, &[0]));
        assert!(!row_key_is_unreadable(&cells, &[1]));
    }

    #[test]
    fn two_rows_with_the_same_undecodable_key_type_do_not_collide() {
        let first = vec![Value::Undecodable("NUMERIC".into()), Value::Text("alice".into())];
        let second = vec![Value::Undecodable("NUMERIC".into()), Value::Text("bob".into())];
        assert!(build_persisted_row_key(first, &[0]).is_none());
        assert!(build_persisted_row_key(second, &[0]).is_none());
    }
}
