use std::sync::Arc;

use async_trait::async_trait;

use super::{ColumnMasks, MaskingPolicy};
use crate::column::ResultColumn;
use crate::result_event::ResultEvent;
use crate::result_sink::{ResultSink, SinkFlow};

// Who reads the rows, which decides how the rules meet the columns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MaskingScope {
    // The grid: by the names the result shows, `table` being the table the rows come from when one is known.
    Grid { table: Option<String> },
    // Every path out of the app: by what each column reads. `table` only for a statement the app wrote over that
    // table's own columns, such as a browse or a table export.
    External { table: Option<String> },
}

impl MaskingScope {
    pub fn masks(&self, policy: &MaskingPolicy, columns: &[ResultColumn]) -> ColumnMasks {
        match self {
            Self::Grid { table } => policy.column_masks(table.as_deref(), columns),
            Self::External { table } => policy.external_column_masks(table.as_deref(), columns),
        }
    }
}

// Masks each row before the sink behind it sees it, so a cut by size or count reads masked values.
pub struct MaskingSink {
    inner: Box<dyn ResultSink>,
    policy: MaskingPolicy,
    scope: MaskingScope,
    visible_columns: Option<usize>,
    sets: usize,
    current: Option<(Arc<[ResultColumn]>, ColumnMasks)>,
}

impl MaskingSink {
    pub fn new(inner: Box<dyn ResultSink>, policy: MaskingPolicy, scope: MaskingScope) -> Self {
        Self {
            inner,
            policy,
            scope,
            visible_columns: None,
            sets: 0,
            current: None,
        }
    }

    // A table page's row addresses follow its visible columns and are never masked.
    #[must_use]
    pub fn with_visible_columns(mut self, count: usize) -> Self {
        self.visible_columns = Some(count);
        self
    }

    // A sink that masks nothing when the policy is empty, so the rows pass through untouched.
    pub fn wrap(inner: Box<dyn ResultSink>, policy: MaskingPolicy, scope: MaskingScope) -> Box<dyn ResultSink> {
        match policy.is_empty() {
            true => inner,
            false => Box::new(Self::new(inner, policy, scope)),
        }
    }

    fn start(&mut self, columns: &Arc<[ResultColumn]>) {
        let masks = self.scope.masks(&self.policy, columns);
        let masks = match self.visible_columns {
            Some(count) => masks.first(count),
            None => masks,
        };
        self.current = Some((columns.clone(), masks));
    }
}

#[async_trait]
impl ResultSink for MaskingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let event = match event {
            ResultEvent::ResultSetStarted { columns } => {
                self.sets += 1;
                self.start(&columns);
                ResultEvent::ResultSetStarted { columns }
            }
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if set_index + 1 == self.sets {
                    self.start(&columns);
                }
                ResultEvent::ColumnsResolved { set_index, columns }
            }
            ResultEvent::Rows(mut rows) => {
                // Rows with no set before them have no columns to match, so none goes out unmasked.
                let Some((columns, masks)) = &self.current else {
                    return SinkFlow::ConsumerGone;
                };
                masks.apply_rows(columns, &mut rows);
                ResultEvent::Rows(rows)
            }
            other => other,
        };
        self.inner.accept(event).await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;
    use crate::column::{ColumnOrigin, ColumnType};
    use crate::masking::{MaskingRule, MaskingStyle, MaskingTarget};
    use crate::meta::TableRef;
    use crate::value::Value;

    struct Recorder(Arc<Mutex<Vec<ResultEvent>>>);

    #[async_trait]
    impl ResultSink for Recorder {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            self.0.lock().expect("events").push(event);
            SinkFlow::Continue
        }
    }

    fn email_policy() -> MaskingPolicy {
        MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )])
    }

    fn columns(origin: bool) -> Arc<[ResultColumn]> {
        let email = ResultColumn::new("contact", ColumnType::untyped_text("text"));
        let email = match origin {
            true => email.with_origin(Some(ColumnOrigin::new(TableRef::unqualified("users"), "email"))),
            false => email,
        };
        vec![email].into()
    }

    fn rows(events: &[ResultEvent]) -> Vec<Vec<Value>> {
        events
            .iter()
            .filter_map(|event| match event {
                ResultEvent::Rows(rows) => Some(rows.clone()),
                _ => None,
            })
            .flatten()
            .collect()
    }

    async fn run(scope: MaskingScope, origin: bool) -> Vec<ResultEvent> {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut sink = MaskingSink::new(Box::new(Recorder(events.clone())), email_policy(), scope);
        sink.accept(ResultEvent::ResultSetStarted {
            columns: columns(origin),
        })
        .await;
        sink.accept(ResultEvent::Rows(vec![vec![Value::Text("ann@example.com".to_owned())]]))
            .await;
        events.lock().expect("events").clone()
    }

    #[tokio::test]
    async fn an_external_reader_gets_rows_masked_by_origin() {
        let events = run(MaskingScope::External { table: None }, true).await;

        assert_eq!(rows(&events), [[Value::Text("a•••@example.com".to_owned())]]);
    }

    #[tokio::test]
    async fn an_untraced_column_is_masked_whole_for_an_external_reader() {
        let events = run(MaskingScope::External { table: None }, false).await;

        assert_eq!(rows(&events), [[Value::Text("••••".to_owned())]]);
    }

    #[tokio::test]
    async fn the_grid_goes_by_the_name_the_result_shows() {
        let events = run(MaskingScope::Grid { table: None }, true).await;

        assert_eq!(rows(&events), [[Value::Text("ann@example.com".to_owned())]]);
    }

    #[tokio::test]
    async fn rows_before_any_set_stop_the_run() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut sink = MaskingSink::new(
            Box::new(Recorder(events.clone())),
            email_policy(),
            MaskingScope::External { table: None },
        );

        let flow = sink.accept(ResultEvent::Rows(vec![vec![Value::Int(1)]])).await;

        assert_eq!(flow, SinkFlow::ConsumerGone);
        assert!(events.lock().expect("events").is_empty());
    }

    #[tokio::test]
    async fn columns_resolved_for_the_current_set_are_matched_again() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut sink = MaskingSink::new(
            Box::new(Recorder(events.clone())),
            email_policy(),
            MaskingScope::Grid { table: None },
        );
        sink.accept(ResultEvent::ResultSetStarted {
            columns: vec![ResultColumn::new("c", ColumnType::untyped_text(""))].into(),
        })
        .await;
        let resolved: Arc<[ResultColumn]> = vec![ResultColumn::new("email", ColumnType::untyped_text("text"))].into();

        sink.accept(ResultEvent::ColumnsResolved {
            set_index: 0,
            columns: resolved,
        })
        .await;
        sink.accept(ResultEvent::Rows(vec![vec![Value::Text("ann@x.io".to_owned())]]))
            .await;

        assert_eq!(
            rows(&events.lock().expect("events")),
            [[Value::Text("a•••@x.io".to_owned())]]
        );
    }
}
