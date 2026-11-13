// Masking for the Windows app: a connection's rules, the grid's masked columns, the share sheet's column choices and
// what the detectors suggest. The engine is `tablepro_core::masking` (core ADR 0028).

use std::sync::Arc;

use tablepro_core::Truncation;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::SnapshotTooLarge;
use tablepro_core::masking::detect::{
    MaskSuggestion, PersonalDataHit, SensitiveKind, SuggestionReason, scan_sql_personal_data, suggest_masks,
};
use tablepro_core::masking::{ColumnMasks, MaskingRule, MaskingStyle, MaskingTarget, ShareChoice};
use uuid::Uuid;

use crate::account::share::{rows_sent, sent_row, share_plan, summary_of};
use crate::error::CoreError;
use crate::export::held_row;
use crate::results::{ResultSet, ResultStore};
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MaskStyleTag {
    Full,
    LastFour,
    Email,
    Hash,
    Null,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MaskTargetTag {
    Column,
    Type,
}

// `id` is empty for a rule the form just added. A save drops a rule whose pattern is blank.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MaskingRuleRecord {
    pub id: String,
    pub pattern: String,
    pub target: MaskTargetTag,
    pub style: MaskStyleTag,
}

// What the share sheet does with one shared column. A column the connection's rules mask leaves masked whatever is
// chosen: Keep takes the rule's style, and a style that shows what the rule hides takes Full.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShareColumnChoice {
    Keep,
    Mask { style: MaskStyleTag },
    Remove,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SensitiveKindTag {
    Card,
    Iban,
    Jwt,
    ApiKey,
    Email,
    Phone,
    Ip,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum MaskReason {
    // The term as its words join, such as "apikey" for `stripe_api_key`.
    ColumnName { term: String },
    Values { kind: SensitiveKindTag },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MaskSuggestionInfo {
    pub style: MaskStyleTag,
    pub reason: MaskReason,
}

// Why the connection's rules mask a shared column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuleReason {
    // A rule matches what the column reads.
    Rule,
    // Nothing traced the column to a table column, so it is masked whole whatever its name.
    Untraced,
}

// One shared column as the sheet starts it: `rule` is the style the connection's rules mask it with on the way out,
// which can never be Keep, and `rule_reason` why; otherwise `suggestion` is what the detectors saw, masked by default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareColumnMasking {
    pub name: String,
    pub rule: Option<MaskStyleTag>,
    pub rule_reason: Option<RuleReason>,
    pub suggestion: Option<MaskSuggestionInfo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PersonalDataHitInfo {
    pub kind: SensitiveKindTag,
    // Where the literal starts, from 1.
    pub line: u32,
}

// Why a share cannot go even cut.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SnapshotTooLargeReason {
    // A value of this column is over 256 KiB.
    Cell { column: String },
    // The first row alone is over the 4.5 MB a share's body may weigh.
    FirstRow,
}

// What a share with the sheet's choices sends, for its note: `rows_sent` is what the snapshot keeps under the plan's
// row limit and the body budget, so it can be fewer than `max_rows`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareSummary {
    pub rows_sent: u64,
    pub columns_sent: u32,
    pub columns_truncated: bool,
    pub too_large: Option<SnapshotTooLargeReason>,
}

// Personal data in the SQL's single-quoted literals, each kind once per line: the sheet suggests Hide SQL.
#[uniffi::export]
pub fn scan_sql_for_personal_data(sql: String) -> Vec<PersonalDataHitInfo> {
    scan_sql_personal_data(&sql)
        .into_iter()
        .map(PersonalDataHitInfo::from)
        .collect()
}

#[uniffi::export]
impl ResultSet {
    // The share sheet's columns as it starts them, from the set's first `visible_columns` columns and the rows a share
    // of `max_rows` would send: the style the rules mask each with on the way out, else what the detectors suggest.
    pub async fn share_masking(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
    ) -> Result<Vec<ShareColumnMasking>, CoreError> {
        let tasks = crate::runtime::tasks()?;
        let blocking = tasks.clone();
        on_runtime(&tasks, async move {
            blocking
                .spawn_blocking_task(move || share_masking(&self, visible_columns, max_rows))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))
        })
        .await
    }
}

#[uniffi::export]
impl ResultSet {
    // The rows a share of `max_rows` with the sheet's `columns` would send, as a finished set: removed columns left out,
    // every value masked as the snapshot masks it, each column's `masked` the style the snapshot names. The sheet
    // previews from it, since a Stable Hash is the core's to compute.
    pub async fn share_preview(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
        columns: Vec<ShareColumnChoice>,
    ) -> Result<Arc<ResultSet>, CoreError> {
        let tasks = crate::runtime::tasks()?;
        let blocking = tasks.clone();
        on_runtime(&tasks, async move {
            blocking
                .spawn_blocking_task(move || share_preview(&self, visible_columns, max_rows, &columns))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        })
        .await
    }
}

#[uniffi::export]
impl ResultSet {
    // What `create_share` with the same arguments would send, by the same plan and budget: cheap enough for each change
    // of the sheet's choices, run off the UI thread.
    pub async fn share_summary(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
        columns: Vec<ShareColumnChoice>,
    ) -> Result<ShareSummary, CoreError> {
        let tasks = crate::runtime::tasks()?;
        let blocking = tasks.clone();
        on_runtime(&tasks, async move {
            blocking
                .spawn_blocking_task(move || share_summary(&self, visible_columns, max_rows, &columns))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
        })
        .await
    }
}

pub(crate) fn share_summary(
    set: &ResultSet,
    visible_columns: u32,
    max_rows: u32,
    choices: &[ShareColumnChoice],
) -> Result<ShareSummary, CoreError> {
    if !set.is_finished() {
        return Err(CoreError::failed("ffi.share_unfinished", "the rows are still arriving"));
    }
    let (visible, plan) = share_plan(set, visible_columns, choices);
    let summary = summary_of(set, &visible, &plan, max_rows);
    Ok(ShareSummary {
        rows_sent: summary.rows_sent as u64,
        columns_sent: u32::try_from(summary.columns_sent).unwrap_or(u32::MAX),
        columns_truncated: summary.columns_cut,
        too_large: summary.too_large.map(|refused| match refused {
            SnapshotTooLarge::Cell { column } => SnapshotTooLargeReason::Cell { column },
            SnapshotTooLarge::FirstRow => SnapshotTooLargeReason::FirstRow,
        }),
    })
}

pub(crate) fn share_preview(
    set: &ResultSet,
    visible_columns: u32,
    max_rows: u32,
    choices: &[ShareColumnChoice],
) -> Result<Arc<ResultSet>, CoreError> {
    if !set.is_finished() {
        return Err(CoreError::failed("ffi.share_unfinished", "the rows are still arriving"));
    }
    let (visible, plan) = share_plan(set, visible_columns, choices);
    let ended = set.extent();
    let taken = rows_sent(set, &visible, &plan, max_rows)?;
    let rows: Vec<Vec<tablepro_core::Value>> = (0..taken).map(|row| sent_row(set, &visible, &plan, row)).collect();
    let store = ResultStore::with_masking(plan.columns(&visible).into(), None);
    store.append(&rows);
    store.mark_masked(ColumnMasks::new(plan.masked()));
    let truncation = match taken < ended.held || ended.cut {
        true => Truncation::ReadPastLimit,
        false => Truncation::Complete,
    };
    store.finish_as(ended.total, truncation);
    Ok(Arc::new(ResultSet::new(0, Arc::new(store))))
}

fn share_masking(set: &ResultSet, visible_columns: u32, max_rows: u32) -> Vec<ShareColumnMasking> {
    let held = set.result_columns();
    let visible = usize::try_from(visible_columns).unwrap_or(usize::MAX).min(held.len());
    let columns: Vec<ResultColumn> = held[..visible].to_vec();
    let rules = set.external_masks(&columns);
    let untraced = set.untraced_columns(&columns);
    // The rows the snapshot sends with the sheet as it starts, so "at least half" never counts a row that stays behind;
    // none when even the first row cannot go.
    let (_, plan) = share_plan(set, visible_columns, &[]);
    let sent = rows_sent(set, &columns, &plan, max_rows).unwrap_or(0);
    let rows: Vec<Vec<tablepro_core::Value>> = (0..sent).map(|row| held_row(set, row, &columns)).collect();
    suggest_masks(&columns, &rows, &rules)
        .into_iter()
        .zip(&columns)
        .enumerate()
        .map(|(index, (suggestion, column))| {
            let rule = rules.style(index);
            ShareColumnMasking {
                name: column.name.clone(),
                rule: rule.map(MaskStyleTag::from),
                rule_reason: rule.map(|_| match untraced.contains(&index) {
                    true => RuleReason::Untraced,
                    false => RuleReason::Rule,
                }),
                suggestion: suggestion.map(MaskSuggestionInfo::from),
            }
        })
        .collect()
}

impl From<MaskingStyle> for MaskStyleTag {
    fn from(style: MaskingStyle) -> Self {
        match style {
            MaskingStyle::Full => Self::Full,
            MaskingStyle::LastFour => Self::LastFour,
            MaskingStyle::Email => Self::Email,
            MaskingStyle::Hash => Self::Hash,
            MaskingStyle::Null => Self::Null,
        }
    }
}

impl From<MaskStyleTag> for MaskingStyle {
    fn from(tag: MaskStyleTag) -> Self {
        match tag {
            MaskStyleTag::Full => Self::Full,
            MaskStyleTag::LastFour => Self::LastFour,
            MaskStyleTag::Email => Self::Email,
            MaskStyleTag::Hash => Self::Hash,
            MaskStyleTag::Null => Self::Null,
        }
    }
}

impl From<SensitiveKind> for SensitiveKindTag {
    fn from(kind: SensitiveKind) -> Self {
        match kind {
            SensitiveKind::Card => Self::Card,
            SensitiveKind::Iban => Self::Iban,
            SensitiveKind::Jwt => Self::Jwt,
            SensitiveKind::ApiKey => Self::ApiKey,
            SensitiveKind::Email => Self::Email,
            SensitiveKind::Phone => Self::Phone,
            SensitiveKind::Ip => Self::Ip,
        }
    }
}

impl From<MaskSuggestion> for MaskSuggestionInfo {
    fn from(suggestion: MaskSuggestion) -> Self {
        Self {
            style: suggestion.style.into(),
            reason: match suggestion.reason {
                SuggestionReason::ColumnName { term } => MaskReason::ColumnName { term: term.to_owned() },
                SuggestionReason::Values { kind } => MaskReason::Values { kind: kind.into() },
            },
        }
    }
}

impl From<PersonalDataHit> for PersonalDataHitInfo {
    fn from(hit: PersonalDataHit) -> Self {
        Self {
            kind: hit.kind.into(),
            line: hit.line,
        }
    }
}

impl From<&MaskingRule> for MaskingRuleRecord {
    fn from(rule: &MaskingRule) -> Self {
        Self {
            id: rule.id.hyphenated().to_string().to_uppercase(),
            pattern: rule.pattern.clone(),
            target: match rule.target {
                MaskingTarget::Column => MaskTargetTag::Column,
                MaskingTarget::Type => MaskTargetTag::Type,
            },
            style: rule.style.into(),
        }
    }
}

// The rules a save keeps: blank patterns go, and a rule without a readable id gets a new one.
pub(crate) fn saved_rules(records: &[MaskingRuleRecord]) -> Vec<MaskingRule> {
    records
        .iter()
        .filter(|record| !record.pattern.trim().is_empty())
        .map(|record| MaskingRule {
            id: Uuid::try_parse(record.id.trim()).unwrap_or_else(|_| Uuid::new_v4()),
            pattern: record.pattern.clone(),
            target: match record.target {
                MaskTargetTag::Column => MaskingTarget::Column,
                MaskTargetTag::Type => MaskingTarget::Type,
            },
            style: record.style.into(),
        })
        .collect()
}

impl From<ShareColumnChoice> for ShareChoice {
    fn from(choice: ShareColumnChoice) -> Self {
        match choice {
            ShareColumnChoice::Keep => Self::Keep,
            ShareColumnChoice::Mask { style } => Self::Mask(style.into()),
            ShareColumnChoice::Remove => Self::Remove,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rule_crosses_both_ways_and_a_save_drops_blank_patterns() {
        let rule = MaskingRule::new("*.email", MaskingTarget::Column, MaskingStyle::Email);
        let record = MaskingRuleRecord::from(&rule);
        let added = MaskingRuleRecord {
            id: String::new(),
            pattern: "uuid".to_owned(),
            target: MaskTargetTag::Type,
            style: MaskStyleTag::Hash,
        };
        let blank = MaskingRuleRecord {
            pattern: " ".to_owned(),
            ..added.clone()
        };

        let saved = saved_rules(&[record.clone(), added, blank]);

        assert_eq!(record.id, rule.id.to_string().to_uppercase());
        assert_eq!(saved.len(), 2);
        assert_eq!(saved[0], rule);
        assert_eq!(
            (saved[1].target, saved[1].style),
            (MaskingTarget::Type, MaskingStyle::Hash)
        );
        assert!(!saved[1].id.is_nil());
    }

    #[test]
    fn personal_data_in_the_sql_crosses_with_its_kind_and_line() {
        let hits = scan_sql_for_personal_data("SELECT 1;\nWHERE email = 'ann@example.com'".to_owned());

        assert_eq!(
            hits,
            [PersonalDataHitInfo {
                kind: SensitiveKindTag::Email,
                line: 2
            }]
        );
    }

    #[test]
    fn the_sheet_starts_from_the_rules_then_the_detectors() {
        use tablepro_core::column::{ColumnOrigin, ColumnType};
        use tablepro_core::masking::{MaskingPolicy, SharedMaskingPolicy};
        use tablepro_core::meta::TableRef;

        use crate::results::{GridMasking, ResultStore};

        let traced = |name: &str| {
            ResultColumn::new(name, ColumnType::untyped_text("text"))
                .with_origin(Some(ColumnOrigin::new(TableRef::unqualified("users"), name)))
        };
        let columns: Arc<[ResultColumn]> = vec![traced("email"), traced("phone"), traced("note")].into();
        let policy = MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Hash,
        )]);
        let store = Arc::new(ResultStore::with_masking(
            columns,
            Some(GridMasking {
                policy: SharedMaskingPolicy::new(policy),
                named_table: None,
                own_table: None,
                visible: None,
                revealed: true,
            }),
        ));
        let text = |value: &str| tablepro_core::Value::Text(value.to_owned());
        store.append(&[vec![text("ann@example.com"), text("x"), text("4111 1111 1111 1111")]]);
        store.finish();

        let started = share_masking(&ResultSet::new(0, store), 3, 1_000);

        assert_eq!(started[0].rule, Some(MaskStyleTag::Hash));
        assert_eq!(started[0].rule_reason, Some(RuleReason::Rule));
        assert_eq!(started[0].suggestion, None);
        assert_eq!(started[1].rule_reason, None);
        assert_eq!(
            started[1].suggestion,
            Some(MaskSuggestionInfo {
                style: MaskStyleTag::LastFour,
                reason: MaskReason::ColumnName {
                    term: "phone".to_owned()
                },
            })
        );
        assert_eq!(
            started[2].suggestion,
            Some(MaskSuggestionInfo {
                style: MaskStyleTag::LastFour,
                reason: MaskReason::Values {
                    kind: SensitiveKindTag::Card
                },
            })
        );
    }

    #[tokio::test]
    async fn the_preview_shows_what_the_snapshot_sends() {
        use tablepro_core::column::{ColumnOrigin, ColumnType};
        use tablepro_core::masking::{MaskingPolicy, SharedMaskingPolicy, stable_hash};
        use tablepro_core::meta::TableRef;

        use crate::results::GridMasking;

        let traced = |name: &str| {
            ResultColumn::new(name, ColumnType::untyped_text("text"))
                .with_origin(Some(ColumnOrigin::new(TableRef::unqualified("users"), name)))
        };
        let columns: Arc<[ResultColumn]> = vec![traced("id"), traced("email"), traced("phone"), traced("note")].into();
        let policy = MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )]);
        let store = Arc::new(ResultStore::with_masking(
            columns,
            Some(GridMasking {
                policy: SharedMaskingPolicy::new(policy),
                named_table: None,
                own_table: None,
                visible: None,
                revealed: true,
            }),
        ));
        let text = |value: &str| tablepro_core::Value::Text(value.to_owned());
        store.append(&[
            vec![text("1"), text("ann@example.com"), text("+1 555 0100"), text("vip")],
            vec![text("2"), text("bob@example.com"), text("+1 555 0199"), text("new")],
        ]);
        store.finish();
        let set = ResultSet::new(0, store);
        let choices = [
            ShareColumnChoice::Remove,
            ShareColumnChoice::Keep,
            ShareColumnChoice::Mask {
                style: MaskStyleTag::Hash,
            },
        ];

        let preview = share_preview(&set, 4, 1, &choices).unwrap();

        let marks: Vec<(String, Option<MaskStyleTag>)> = preview
            .columns()
            .into_iter()
            .map(|column| (column.name, column.masked))
            .collect();
        assert_eq!(
            marks,
            [
                ("email".to_owned(), Some(MaskStyleTag::Email)),
                ("phone".to_owned(), Some(MaskStyleTag::Hash)),
                ("note".to_owned(), None),
            ]
        );
        assert_eq!(preview.row_count(), 1);
        assert!(preview.is_finished());
        assert_eq!(preview.cell_text(0, 0).unwrap().as_deref(), Some("a•••@example.com"));
        assert_eq!(preview.cell_text(0, 1).unwrap(), Some(stable_hash(b"+1 555 0100")));
        assert_eq!(preview.cell_text(0, 2).unwrap().as_deref(), Some("vip"));
        assert!(!preview.remask().await.unwrap(), "a preview was masked again");
    }

    #[test]
    fn detection_reads_only_the_rows_a_share_sends_and_names_an_untraced_mask() {
        use tablepro_core::column::ColumnType;
        use tablepro_core::masking::{MaskingPolicy, SharedMaskingPolicy};

        use crate::results::{GridMasking, ResultStore};

        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("contact", ColumnType::untyped_text("text"))].into();
        let set = |rules: Vec<MaskingRule>| {
            let store = Arc::new(ResultStore::with_masking(
                columns.clone(),
                Some(GridMasking {
                    policy: SharedMaskingPolicy::new(MaskingPolicy::new(rules)),
                    named_table: None,
                    own_table: None,
                    visible: None,
                    revealed: true,
                }),
            ));
            let text = |value: &str| tablepro_core::Value::Text(value.to_owned());
            store.append(&[
                vec![text("ann@example.com")],
                vec![text("x")],
                vec![text("y")],
                vec![text("z")],
            ]);
            store.finish();
            ResultSet::new(0, store)
        };
        let plain = set(Vec::new());
        let ruled = set(vec![MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )]);

        let sent_one = share_masking(&plain, 1, 1);
        let sent_all = share_masking(&plain, 1, 4);
        let untraced = share_masking(&ruled, 1, 4);

        assert_eq!(
            sent_one[0].suggestion.as_ref().map(|found| found.style),
            Some(MaskStyleTag::Email)
        );
        assert_eq!(sent_all[0].suggestion, None, "rows past the share counted");
        assert_eq!(untraced[0].rule, Some(MaskStyleTag::Full));
        assert_eq!(untraced[0].rule_reason, Some(RuleReason::Untraced));
    }
}
