use std::sync::{Arc, Mutex, PoisonError};

use async_trait::async_trait;
use tablepro_core::browse::{DeclaredPrecisionSink, ExportFields, ExportRequest, SortKey, build_export};
use tablepro_core::column::ResultColumn;
use tablepro_core::export::ResultExtent;
use tablepro_core::meta::{RowIdentity, TableRef};
use tablepro_core::{ColumnInfo, FilterSet, ReadStatement, ResultEvent, ResultSink, SinkFlow, Value};
use tablepro_session::{OperationError, OperationKind, Session};

use super::grid::RowSnapshot;
use super::share_subject::SharedRows;

// A table tab's view, read from its first row once the plan says how many rows a link carries.
#[derive(Debug, Clone)]
pub struct TableShare {
    pub session: Arc<Session>,
    pub table: TableRef,
    // Every column, so the filter and the sort find theirs; `shown` picks what the link carries.
    pub columns: Arc<[ColumnInfo]>,
    pub shown: Vec<usize>,
    pub filter: FilterSet,
    pub sort: Vec<SortKey>,
    pub identity: RowIdentity,
    // What the tab counted or estimated, which the link names as the whole.
    pub total: Option<u64>,
}

#[derive(Default)]
struct Collected {
    columns: Option<Arc<[ResultColumn]>>,
    rows: Vec<Vec<Value>>,
    full: bool,
}

// Stops the read once it holds the plan's rows; a link carries no more.
struct FirstRows {
    state: Arc<Mutex<Collected>>,
    max_rows: usize,
}

impl TableShare {
    pub fn request(&self) -> ExportRequest<'_> {
        ExportRequest {
            table: &self.table,
            columns: &self.columns,
            filter: &self.filter,
            sort: &self.sort,
            identity: &self.identity,
            fields: ExportFields::Listed,
        }
    }

    pub(crate) async fn read(self: Arc<Self>, max_rows: u64) -> Result<SharedRows, OperationError> {
        let max_rows = usize::try_from(max_rows).unwrap_or(usize::MAX);
        let state = Arc::new(Mutex::new(Collected::default()));
        let (share, reading) = (self.clone(), state.clone());
        let ran = self
            .session
            .run(OperationKind::Export, move |lease, options| {
                let (share, state) = (share.clone(), reading.clone());
                async move {
                    *state.lock().unwrap_or_else(PoisonError::into_inner) = Collected::default();
                    let read = ReadStatement::Generated(build_export(&*lease.dialect(), &share.request())?);
                    let sink =
                        DeclaredPrecisionSink::new(Box::new(FirstRows { state, max_rows }), share.columns.clone());
                    Ok(lease.stream_read(&read, Box::new(sink), options).await?)
                }
            })
            .await;
        let collected = std::mem::take(&mut *state.lock().unwrap_or_else(PoisonError::into_inner));
        match ran {
            Ok(_) => {}
            // The sink ends a read it has had enough of, which some drivers report as a failure.
            Err(_) if collected.full => {}
            Err(error) => return Err(error),
        }
        Ok(self.shared(collected))
    }

    fn shared(&self, collected: Collected) -> SharedRows {
        let read: Arc<[ResultColumn]> = collected
            .columns
            .unwrap_or_else(|| self.columns.iter().map(ColumnInfo::result_column).collect());
        let shown: Vec<usize> = self.shown.iter().copied().filter(|index| *index < read.len()).collect();
        let columns: Arc<[ResultColumn]> = shown.iter().map(|index| read[*index].clone()).collect();
        let full = collected.full;
        let rows: Vec<RowSnapshot> = collected
            .rows
            .into_iter()
            .map(|row| {
                let cells: Vec<Value> = shown
                    .iter()
                    .map(|index| row.get(*index).cloned().unwrap_or(Value::Null))
                    .collect();
                RowSnapshot::new(cells.into(), Vec::new())
            })
            .collect();
        let held = rows.len() as u64;
        let extent = match self.total {
            Some(total) => ResultExtent {
                held,
                total: Some(total),
                cut: true,
            },
            None => ResultExtent {
                held,
                total: None,
                cut: full,
            },
        };
        SharedRows { columns, rows, extent }
    }
}

#[async_trait]
impl ResultSink for FirstRows {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        match event {
            ResultEvent::ResultSetStarted { columns } if state.columns.is_none() => state.columns = Some(columns),
            ResultEvent::ColumnsResolved { set_index: 0, columns } => state.columns = Some(columns),
            ResultEvent::Rows(rows) => {
                let room = self.max_rows.saturating_sub(state.rows.len());
                state.rows.extend(rows.into_iter().take(room));
            }
            _ => {}
        }
        if state.rows.len() >= self.max_rows {
            state.full = true;
            return SinkFlow::ConsumerGone;
        }
        SinkFlow::Continue
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, classify_type_name};
    use tablepro_core::{ResultEvent, Truncation};
    use tablepro_test_support::{ConnectionScript, FakeReply};

    use super::*;
    use crate::test_support::{FakeSession, paused_tasks};

    fn column(name: &str) -> ColumnInfo {
        crate::services::grid::test_columns::info(name, "text")
    }

    fn table(session: Arc<Session>, total: Option<u64>) -> Arc<TableShare> {
        Arc::new(TableShare {
            session,
            table: TableRef::new(None, "orders"),
            columns: vec![column("id"), column("secret"), column("name")].into(),
            shown: vec![2, 0],
            filter: FilterSet::default(),
            sort: Vec::new(),
            identity: RowIdentity::UniqueKey {
                columns: vec!["id".to_owned()],
            },
            total,
        })
    }

    fn events(rows: usize) -> Vec<ResultEvent> {
        let columns: Arc<[ResultColumn]> = ["id", "secret", "name"]
            .into_iter()
            .map(|name| {
                ResultColumn::new(
                    name,
                    ColumnType {
                        kind: classify_type_name("text"),
                        ..ColumnType::untyped_text("text")
                    },
                )
            })
            .collect();
        vec![
            ResultEvent::ResultSetStarted { columns },
            ResultEvent::Rows(
                (0..rows)
                    .map(|row| {
                        vec![
                            Value::Text(row.to_string()),
                            Value::Text("hidden".to_owned()),
                            Value::Text(format!("name {row}")),
                        ]
                    })
                    .collect(),
            ),
            ResultEvent::ResultSetFinished {
                retained: rows as u64,
                total_rows: Some(rows as u64),
                truncation: Truncation::Complete,
            },
        ]
    }

    #[tokio::test]
    async fn a_table_share_reads_the_plans_rows_under_the_shown_columns_with_the_tabs_total() {
        let mut script = ConnectionScript::default();
        script.stream_read.always(FakeReply::ok(events(8)));
        let fake = FakeSession::start(script, [], paused_tasks());
        let share = table(fake.session.clone(), Some(48_210));

        let shared = share.read(5).await.expect("the rows read");

        assert_eq!(
            shared
                .columns
                .iter()
                .map(|column| column.name.as_str())
                .collect::<Vec<_>>(),
            ["name", "id"]
        );
        assert_eq!(shared.rows.len(), 5);
        assert_eq!(
            shared.rows[4].to_values(),
            [Value::Text("name 4".to_owned()), Value::Text("4".to_owned())]
        );
        assert_eq!(shared.total(), 48_210);
    }

    #[tokio::test]
    async fn without_a_count_the_whole_is_the_rows_read() {
        let mut script = ConnectionScript::default();
        script.stream_read.always(FakeReply::ok(events(3)));
        let fake = FakeSession::start(script, [], paused_tasks());

        let shared = table(fake.session.clone(), None)
            .read(1_000)
            .await
            .expect("the rows read");

        assert_eq!(shared.rows.len(), 3);
        assert_eq!(shared.total(), 3);
        assert_eq!((shared.extent.total, shared.extent.cut), (None, false));
    }
}
