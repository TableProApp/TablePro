use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::{ByteLimit, ResultEvent, ResultSink, SinkFlow};

use super::{RunEvent, RunState};
use crate::results::{ResultColumnInfo, ResultStore};

// Rows go into the set's store at once, so the read runs at the server's pace and not the grid's.
pub(crate) struct RunSink {
    state: Arc<RunState>,
    current: Option<(u32, Arc<ResultStore>)>,
    limit_bytes: u64,
}

impl RunSink {
    pub(crate) fn new(state: Arc<RunState>, byte_limit: ByteLimit) -> Self {
        Self {
            state,
            current: None,
            limit_bytes: byte_limit.get(),
        }
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
            ResultEvent::ByteLimitReached { retained } => RunEvent::ByteLimitReached {
                set_index: self.current_index(),
                retained,
                limit_bytes: self.limit_bytes,
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
            ResultEvent::NoticeLimitReached { retained } => RunEvent::NoticeLimitReached { retained },
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

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::{ServerNotice, Truncation, Value};

    use super::*;
    use crate::run::{RunListener, TruncationTag};

    struct Quiet;

    impl RunListener for Quiet {
        fn events_pending(&self) {}
    }

    #[tokio::test]
    async fn a_set_cut_for_bytes_reaches_the_app_with_the_runs_limit() {
        let state = Arc::new(RunState::new(Box::new(Quiet)));
        let limit = ByteLimit::new(4_096).unwrap();
        let mut sink = RunSink::new(state.clone(), limit);
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("blob", ColumnType::untyped_text(""))].into();

        sink.accept(ResultEvent::ResultSetStarted { columns }).await;
        sink.accept(ResultEvent::Rows(vec![vec![Value::Text("a".repeat(5_000))]]))
            .await;
        sink.accept(ResultEvent::ByteLimitReached { retained: 1 }).await;
        sink.accept(ResultEvent::ResultSetFinished {
            retained: 1,
            total_rows: Some(3),
            truncation: Truncation::ByteLimit,
        })
        .await;

        let events = state.drain();
        assert_eq!(
            events[2],
            RunEvent::ByteLimitReached {
                set_index: 0,
                retained: 1,
                limit_bytes: 4_096,
            }
        );
        assert_eq!(
            events[3],
            RunEvent::ResultSetFinished {
                set_index: 0,
                row_count: 1,
                total_rows: Some(3),
                truncation: TruncationTag::ByteLimit,
            }
        );
    }

    #[tokio::test]
    async fn the_notice_limit_reaches_the_app_after_the_notices_kept() {
        let state = Arc::new(RunState::new(Box::new(Quiet)));
        let mut sink = RunSink::new(state.clone(), ByteLimit::EDITOR_DEFAULT);

        sink.accept(ResultEvent::Notice(ServerNotice {
            severity: "NOTICE".to_owned(),
            message: "row 1".to_owned(),
            code: None,
        }))
        .await;
        sink.accept(ResultEvent::NoticeLimitReached { retained: 1 }).await;

        assert_eq!(
            state.drain(),
            [
                RunEvent::Notice {
                    severity: "NOTICE".to_owned(),
                    message: "row 1".to_owned(),
                    code: None,
                },
                RunEvent::NoticeLimitReached { retained: 1 },
            ]
        );
    }
}
