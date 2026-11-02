use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ResultEvent, ResultSink, SinkFlow};

use super::{RunEvent, RunState};
use crate::results::{ResultColumnInfo, ResultStore};

/// Takes a run's events as the driver reads them: rows go into the
/// set's store at once, so the read runs at the server's pace and not
/// the grid's.
pub(crate) struct RunSink {
    state: Arc<RunState>,
    current: Option<(u32, Arc<ResultStore>)>,
}

impl RunSink {
    pub(crate) fn new(state: Arc<RunState>) -> Self {
        Self { state, current: None }
    }
}

#[async_trait]
impl ResultSink for RunSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let event = match event {
            ResultEvent::ResultSetStarted { columns } => {
                let infos = columns.iter().map(ResultColumnInfo::from).collect();
                let store = Arc::new(ResultStore::new(columns));
                let set_index = self.state.add_set(store.clone());
                self.current = Some((set_index, store));
                RunEvent::ResultSetStarted {
                    set_index,
                    columns: infos,
                }
            }
            ResultEvent::ColumnsResolved { set_index, columns } => {
                let set_index = u32::try_from(set_index).unwrap_or(u32::MAX);
                let infos = columns.iter().map(ResultColumnInfo::from).collect();
                if let Some(store) = self.state.set(set_index) {
                    store.resolve_columns(columns);
                }
                RunEvent::ColumnsResolved {
                    set_index,
                    columns: infos,
                }
            }
            ResultEvent::Rows(rows) => {
                let Some((set_index, store)) = &self.current else {
                    return SinkFlow::Continue;
                };
                RunEvent::RowsAppended {
                    set_index: *set_index,
                    row_count: store.append(&rows),
                }
            }
            ResultEvent::RowLimitReached { retained } => RunEvent::RowLimitReached {
                set_index: self.current_index(),
                retained,
            },
            ResultEvent::ResultSetFinished {
                total_rows, truncation, ..
            } => {
                let (set_index, row_count) = match self.current.take() {
                    Some((set_index, store)) => {
                        store.finish();
                        (set_index, store.row_count())
                    }
                    None => (u32::MAX, 0),
                };
                RunEvent::ResultSetFinished {
                    set_index,
                    row_count,
                    total_rows,
                    truncation: truncation.into(),
                }
            }
            ResultEvent::CommandCompleted { rows_affected } => RunEvent::CommandCompleted { rows_affected },
            ResultEvent::Notice(notice) => notice.into(),
        };
        self.state.post(event);
        SinkFlow::Continue
    }
}

impl RunSink {
    fn current_index(&self) -> u32 {
        self.current.as_ref().map_or(u32::MAX, |(index, _)| *index)
    }
}
