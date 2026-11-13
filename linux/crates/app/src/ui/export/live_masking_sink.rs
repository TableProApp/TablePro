use std::sync::Arc;

use async_trait::async_trait;
use tablepro_core::column::ResultColumn;
use tablepro_core::masking::{ColumnMasks, MaskingScope, MaskingStyle, SharedMaskingPolicy};
use tablepro_core::{ResultEvent, ResultSink, SinkFlow};

// Masks each batch by the session's rules as they are when it passes, so a rule saved during a long export reaches the
// rows after it. A column keeps the mask its earlier rows left with, tightened by any the new rules add.
pub(crate) struct LiveMaskingSink {
    inner: Box<dyn ResultSink>,
    rules: SharedMaskingPolicy,
    scope: MaskingScope,
    sets: usize,
    current: Option<Current>,
}

struct Current {
    columns: Arc<[ResultColumn]>,
    masks: ColumnMasks,
    generation: u64,
}

impl LiveMaskingSink {
    pub(crate) fn new(inner: Box<dyn ResultSink>, rules: SharedMaskingPolicy, scope: MaskingScope) -> Self {
        Self {
            inner,
            rules,
            scope,
            sets: 0,
            current: None,
        }
    }
}

// The generation first, so rules set between the two reads are read again on the next batch.
fn masks_now(rules: &SharedMaskingPolicy, scope: &MaskingScope, columns: &[ResultColumn]) -> (u64, ColumnMasks) {
    let generation = rules.generation();
    (generation, scope.masks(&rules.get(), columns))
}

fn tightened(held: &ColumnMasks, fresh: &ColumnMasks) -> ColumnMasks {
    let width = held.styles().len().max(fresh.styles().len());
    ColumnMasks::new(
        (0..width)
            .map(|column| MaskingStyle::strictest(held.style(column), fresh.style(column)))
            .collect(),
    )
}

#[async_trait]
impl ResultSink for LiveMaskingSink {
    async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
        let event = match event {
            ResultEvent::ResultSetStarted { columns } => {
                self.sets += 1;
                let (generation, masks) = masks_now(&self.rules, &self.scope, &columns);
                self.current = Some(Current {
                    columns: columns.clone(),
                    masks,
                    generation,
                });
                ResultEvent::ResultSetStarted { columns }
            }
            ResultEvent::ColumnsResolved { set_index, columns } => {
                if set_index + 1 == self.sets {
                    let (generation, fresh) = masks_now(&self.rules, &self.scope, &columns);
                    let held = self.current.take().map(|current| current.masks).unwrap_or_default();
                    self.current = Some(Current {
                        columns: columns.clone(),
                        masks: tightened(&held, &fresh),
                        generation,
                    });
                }
                ResultEvent::ColumnsResolved { set_index, columns }
            }
            ResultEvent::Rows(mut rows) => {
                // Rows with no set before them have no columns to match, so none goes out unmasked.
                let Some(current) = self.current.as_mut() else {
                    return SinkFlow::ConsumerGone;
                };
                if self.rules.generation() != current.generation {
                    let (generation, fresh) = masks_now(&self.rules, &self.scope, &current.columns);
                    current.masks = tightened(&current.masks, &fresh);
                    current.generation = generation;
                }
                current.masks.apply_rows(&current.columns, &mut rows);
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

    use tablepro_core::Value;
    use tablepro_core::column::ColumnType;
    use tablepro_core::masking::{MaskingPolicy, MaskingRule, MaskingTarget};

    use super::*;

    struct Recorder(Arc<Mutex<Vec<Vec<Value>>>>);

    #[async_trait]
    impl ResultSink for Recorder {
        async fn accept(&mut self, event: ResultEvent) -> SinkFlow {
            if let ResultEvent::Rows(rows) = event {
                self.0.lock().expect("rows").extend(rows);
            }
            SinkFlow::Continue
        }
    }

    #[tokio::test]
    async fn a_rule_saved_during_the_export_masks_the_rows_after_it() {
        let rules = SharedMaskingPolicy::default();
        let written = Arc::new(Mutex::new(Vec::new()));
        let mut sink = LiveMaskingSink::new(
            Box::new(Recorder(written.clone())),
            rules.clone(),
            MaskingScope::External {
                table: Some("users".to_owned()),
            },
        );
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("email", ColumnType::untyped_text("text"))].into();
        let row = |email: &str| vec![Value::Text(email.to_owned())];

        sink.accept(ResultEvent::ResultSetStarted { columns }).await;
        sink.accept(ResultEvent::Rows(vec![row("ann@example.com")])).await;
        rules.set(MaskingPolicy::new([MaskingRule::new(
            "email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )]));
        sink.accept(ResultEvent::Rows(vec![row("bo@example.com")])).await;

        assert_eq!(
            *written.lock().expect("rows"),
            [row("ann@example.com"), row("b•••@example.com")]
        );
    }
}
