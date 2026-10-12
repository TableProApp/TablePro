use super::{WorkspaceState, WorkspaceStore, WorkspaceTabRecord, load_locked, save_locked};

impl WorkspaceStore {
    pub fn discard_preview_tabs(&self) {
        let _guard = self
            .inner
            .file_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Ok(mut state) = load_locked() else {
            return;
        };
        if drop_preview_tabs(&mut state) && save_locked(&state).is_err() {
            tracing::warn!("preview tabs could not be discarded from the saved workspace");
        }
    }
}

fn drop_preview_tabs(state: &mut WorkspaceState) -> bool {
    let mut changed = false;
    for conn in state.connections.values_mut() {
        let selected = conn.active_idx as usize;
        let mut active_index = None;
        let mut retained = 0;
        let mut original = 0;
        conn.tabs.retain(|tab| {
            let keep = !matches!(tab, WorkspaceTabRecord::Table { preview: true, .. });
            changed |= !keep;
            if keep {
                if original == selected {
                    active_index = Some(retained);
                }
                retained += 1;
            }
            original += 1;
            keep
        });
        conn.active_idx = active_index.unwrap_or(0);
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::drop_preview_tabs;
    use crate::services::workspace_state::{
        ConnectionWorkspaceState, PersistedTableMode, RestoredWorkspaceTab, WorkspaceState, WorkspaceTabRecord,
        restored_workspace_tab,
    };

    fn table(name: &str, preview: bool) -> WorkspaceTabRecord {
        WorkspaceTabRecord::Table {
            schema: None,
            table: name.into(),
            mode: PersistedTableMode::Data,
            offset: 0,
            page_size: 100,
            sort_col: None,
            sort_asc: None,
            preview,
        }
    }

    fn state_with(tabs: Vec<WorkspaceTabRecord>, active_idx: u32) -> WorkspaceState {
        let mut state = WorkspaceState::default();
        state.connections.insert(
            "c".into(),
            ConnectionWorkspaceState {
                tabs,
                active_idx,
                ..Default::default()
            },
        );
        state
    }

    #[test]
    fn startup_drops_preview_tabs_and_keeps_the_selected_kept_tab() {
        let mut state = state_with(vec![table("one", true), table("kept", false), table("two", true)], 1);
        assert!(drop_preview_tabs(&mut state));
        let conn = &state.connections["c"];
        assert_eq!(conn.tabs.len(), 1);
        assert_eq!(conn.active_idx, 0);
        assert!(matches!(&conn.tabs[0], WorkspaceTabRecord::Table { table, preview: false, .. } if table == "kept"));
    }

    #[test]
    fn a_selected_preview_tab_falls_back_to_the_first_kept_tab() {
        let mut state = state_with(vec![table("kept", false), table("one", true)], 1);
        drop_preview_tabs(&mut state);
        assert_eq!(state.connections["c"].active_idx, 0);
    }

    #[test]
    fn a_preview_table_record_restores_as_a_preview_tab() {
        assert!(matches!(
            restored_workspace_tab(&table("jobs", true)),
            Some(RestoredWorkspaceTab::Table { preview: true, .. })
        ));
        assert!(matches!(
            restored_workspace_tab(&table("jobs", false)),
            Some(RestoredWorkspaceTab::Table { preview: false, .. })
        ));
    }
}
