// What a pass leaves waiting, said in the log after it: per kind, the records held by reason and the records with a
// value waiting for the person. Only kinds, reason names and counts go in, never a record's id or values, so a host may
// show them in its log as public.

use std::collections::{BTreeMap, BTreeSet};

use crate::api::state::{ApprovalDecision, Row};
use crate::state::held_reason_name;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Waiting {
    held: BTreeMap<(String, &'static str), usize>,
    approvals: BTreeMap<String, usize>,
}

impl Waiting {
    pub fn of<'a>(rows: impl Iterator<Item = &'a Row>) -> Self {
        let mut held: BTreeMap<(String, &'static str), usize> = BTreeMap::new();
        let mut waiting: BTreeMap<String, BTreeSet<&str>> = BTreeMap::new();
        for row in rows {
            match row {
                Row::Held(row) => {
                    *held
                        .entry((row.key.kind.as_str().to_owned(), held_reason_name(row.reason)))
                        .or_default() += 1;
                }
                Row::Approval(row) if row.decision == ApprovalDecision::Waiting => {
                    waiting
                        .entry(row.key.kind.as_str().to_owned())
                        .or_default()
                        .insert(row.key.record_id.as_str());
                }
                _ => {}
            }
        }
        Self {
            held,
            approvals: waiting
                .into_iter()
                .map(|(kind, records)| (kind, records.len()))
                .collect(),
        }
    }

    // At info when it differs from what the last pass left, so a stall reads once in a persisted log and each pass
    // after it only at debug.
    pub fn log(&self, last: &Self) {
        let changed = self != last;
        for ((kind, reason), count) in &self.held {
            if changed {
                tracing::info!(kind = kind.as_str(), reason = *reason, count = *count, "records held");
            } else {
                tracing::debug!(kind = kind.as_str(), reason = *reason, count = *count, "records held");
            }
        }
        for (kind, count) in &self.approvals {
            if changed {
                tracing::info!(
                    kind = kind.as_str(),
                    count = *count,
                    "records wait for the person's approval"
                );
            } else {
                tracing::debug!(
                    kind = kind.as_str(),
                    count = *count,
                    "records wait for the person's approval"
                );
            }
        }
        if changed && self.held.is_empty() && self.approvals.is_empty() {
            tracing::info!("no record held or waiting for approval");
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use serde_json::json;
    use tablepro_records::Kind;
    use tracing::Level;

    use super::*;
    use crate::api::ids::{ChangeTag, KindName, RecordKey, ScopeName};
    use crate::api::state::{ApprovalRow, HeldReason, HeldRow};
    use crate::api::transport::PulledRecord;

    fn key(id: &str) -> RecordKey {
        RecordKey::new(ScopeName::Personal, Kind::Connection, id)
    }

    fn held(id: &str, reason: HeldReason) -> Row {
        Row::Held(HeldRow {
            key: key(id),
            reason,
            record: PulledRecord {
                kind: KindName::of(Kind::Connection),
                record_id: id.to_owned(),
                tag: ChangeTag::Service("tag".to_owned()),
                fields: None,
                fields_json: None,
                deleted: None,
                service: None,
            },
        })
    }

    fn approval(id: &str, field: &str, decision: ApprovalDecision) -> Row {
        Row::Approval(ApprovalRow {
            key: key(id),
            field: field.to_owned(),
            pulled: json!("db.example.com"),
            decision,
        })
    }

    // This module's lines as `message key=value ...`, at their level. Each event asks the subscriber of its own thread,
    // so tests running beside it never decide what a callsite reaches.
    struct Lines(Arc<Mutex<Vec<(Level, String)>>>);

    impl tracing::Subscriber for Lines {
        fn register_callsite(&self, _metadata: &'static tracing::Metadata<'static>) -> tracing::subscriber::Interest {
            tracing::subscriber::Interest::sometimes()
        }

        fn enabled(&self, metadata: &tracing::Metadata<'_>) -> bool {
            metadata.target() == module_path!().trim_end_matches("::tests")
        }

        fn new_span(&self, _span: &tracing::span::Attributes<'_>) -> tracing::span::Id {
            tracing::span::Id::from_u64(1)
        }

        fn record(&self, _span: &tracing::span::Id, _values: &tracing::span::Record<'_>) {}

        fn record_follows_from(&self, _span: &tracing::span::Id, _follows: &tracing::span::Id) {}

        fn event(&self, event: &tracing::Event<'_>) {
            struct Text(String, Vec<String>);
            impl tracing::field::Visit for Text {
                fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
                    if field.name() == "message" {
                        self.0 = format!("{value:?}");
                    } else {
                        self.1.push(format!("{}={value:?}", field.name()));
                    }
                }

                fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
                    self.1.push(format!("{}={value}", field.name()));
                }
            }
            let mut text = Text(String::new(), Vec::new());
            event.record(&mut text);
            let mut line = text.0;
            for field in text.1 {
                line.push(' ');
                line.push_str(&field);
            }
            self.0.lock().unwrap().push((*event.metadata().level(), line));
        }

        fn enter(&self, _span: &tracing::span::Id) {}

        fn exit(&self, _span: &tracing::span::Id) {}
    }

    fn logged(waiting: &Waiting, last: &Waiting) -> Vec<(Level, String)> {
        let lines = Arc::new(Mutex::new(Vec::new()));
        tracing::subscriber::with_default(Lines(Arc::clone(&lines)), || waiting.log(last));
        lines.lock().unwrap().clone()
    }

    // E2E F14: the app log said nothing while two connections waited.
    #[test]
    fn a_pass_logs_per_kind_what_it_leaves_held_and_waiting_without_ids_or_values() {
        let rows = [
            held("C1", HeldReason::AwaitingApproval),
            held("C2", HeldReason::AwaitingApproval),
            held("C3", HeldReason::Unreadable),
            approval("C1", "/host", ApprovalDecision::Waiting),
            approval("C1", "/port", ApprovalDecision::Waiting),
            approval("C2", "/host", ApprovalDecision::Waiting),
            approval(
                "C3",
                "/host",
                ApprovalDecision::Rejected {
                    local: json!("mine.example.com"),
                },
            ),
        ];
        let waiting = Waiting::of(rows.iter());

        let first = logged(&waiting, &Waiting::default());
        let again = logged(&waiting, &waiting);

        assert_eq!(
            first,
            [
                (
                    Level::INFO,
                    "records held kind=connection reason=awaiting_approval count=2".to_owned()
                ),
                (
                    Level::INFO,
                    "records held kind=connection reason=unreadable count=1".to_owned()
                ),
                (
                    Level::INFO,
                    "records wait for the person's approval kind=connection count=2".to_owned()
                ),
            ]
        );
        assert_eq!(again.len(), 3);
        assert!(again.iter().all(|(level, _)| *level == Level::DEBUG));
        assert!(
            first
                .iter()
                .all(|(_, line)| !line.contains("C1") && !line.contains("example.com"))
        );
    }

    #[test]
    fn a_pass_that_leaves_nothing_after_one_that_did_says_so_once() {
        let before = Waiting::of([held("C1", HeldReason::Unreadable)].iter());

        assert_eq!(
            logged(&Waiting::default(), &before),
            [(Level::INFO, "no record held or waiting for approval".to_owned())]
        );
        assert!(logged(&Waiting::default(), &Waiting::default()).is_empty());
    }
}
