// Masking a shared result for the Windows app: the share sheet's column choices, what the detectors suggest, the
// preview as sent and its summary. The engine is `tablepro_core::masking` (core ADR 0028).

use std::sync::Arc;

use tablepro_account::MAX_SHARE_COLUMNS;
use tablepro_core::Truncation;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::SnapshotRefusal;
use tablepro_core::masking::detect::{
    MaskSuggestion, PersonalDataHit, SensitiveKind, SuggestionReason, scan_sql_personal_data,
};
use tablepro_core::masking::{MaskingStyle, ShareChoice, share_suggestions};

use crate::account::share::{rows_sent, sent_row, share_plan, summary_of, visible_columns_of};
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

// What the share sheet does with one shared column.
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

// One shared column as the sheet starts it: with a suggestion, Mask in that style by default, which the user may Keep.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareColumnMasking {
    pub name: String,
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
pub enum ShareRefusal {
    // A value of this column is over 256 KiB.
    Cell { column: String },
    // The first row alone is over the 4.5 MB a share's body may weigh.
    FirstRow,
    // The sheet removed every column.
    NoColumns,
}

// What a share with the sheet's choices sends, for its note: `rows_sent` is what the snapshot keeps under the plan's
// row limit and the body budget, so it can be fewer than `max_rows`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareSummary {
    pub rows_sent: u64,
    pub columns_sent: u32,
    pub columns_truncated: bool,
    pub refused: Option<ShareRefusal>,
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
    // The share sheet's columns as it starts them, from the set's first `visible_columns` columns and its first
    // `max_rows` rows (`tablepro_core::masking::share_suggestions`).
    pub async fn share_masking(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
    ) -> Result<Vec<ShareColumnMasking>, CoreError> {
        off_the_caller(move || Ok(share_masking(&self, visible_columns, max_rows))).await
    }

    // The rows a share of `max_rows` with the sheet's `columns` would send, as a finished set: removed columns left out
    // and every value masked as the snapshot masks it. The sheet previews from it, since a Stable Hash is the core's to
    // compute.
    pub async fn share_preview(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
        columns: Vec<ShareColumnChoice>,
    ) -> Result<Arc<ResultSet>, CoreError> {
        off_the_caller(move || share_preview(&self, visible_columns, max_rows, &columns)).await
    }

    // What `create_share` with the same arguments would send, by the same plan and budget: cheap enough for each change
    // of the sheet's choices, run off the UI thread.
    pub async fn share_summary(
        self: Arc<Self>,
        visible_columns: u32,
        max_rows: u32,
        columns: Vec<ShareColumnChoice>,
    ) -> Result<ShareSummary, CoreError> {
        off_the_caller(move || share_summary(&self, visible_columns, max_rows, &columns)).await
    }
}

async fn off_the_caller<T, F>(work: F) -> Result<T, CoreError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, CoreError> + Send + 'static,
{
    let tasks = crate::runtime::tasks()?;
    let blocking = tasks.clone();
    on_runtime(&tasks, async move {
        blocking
            .spawn_blocking_task(work)
            .await
            .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))?
    })
    .await
}

fn share_masking(set: &ResultSet, visible_columns: u32, max_rows: u32) -> Vec<ShareColumnMasking> {
    let columns = visible_columns_of(set, visible_columns);
    let held = (0..set.extent().held).map(|row| held_row(set, row, &columns));
    share_suggestions(
        &columns,
        held,
        usize::try_from(max_rows).unwrap_or(usize::MAX),
        MAX_SHARE_COLUMNS,
    )
    .into_iter()
    .zip(&columns)
    .map(|(suggestion, column)| ShareColumnMasking {
        name: column.name.clone(),
        suggestion: suggestion.map(MaskSuggestionInfo::from),
    })
    .collect()
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
    let columns: Arc<[ResultColumn]> = plan.columns(&visible).into();
    let store = ResultStore::new(columns);
    store.append(&rows);
    let truncation = match taken < ended.held || ended.cut {
        true => Truncation::ReadPastLimit,
        false => Truncation::Complete,
    };
    store.finish_as(ended.total, truncation);
    Ok(Arc::new(ResultSet::new(0, Arc::new(store))))
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
        refused: summary.refused.map(ShareRefusal::from),
    })
}

impl From<SnapshotRefusal> for ShareRefusal {
    fn from(refused: SnapshotRefusal) -> Self {
        match refused {
            SnapshotRefusal::Cell { column } => Self::Cell { column },
            SnapshotRefusal::FirstRow => Self::FirstRow,
            SnapshotRefusal::NoColumns => Self::NoColumns,
        }
    }
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

impl From<ShareColumnChoice> for ShareChoice {
    fn from(choice: ShareColumnChoice) -> Self {
        match choice {
            ShareColumnChoice::Keep => Self::Keep,
            ShareColumnChoice::Mask { style } => Self::Mask(style.into()),
            ShareColumnChoice::Remove => Self::Remove,
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

#[cfg(test)]
mod tests {
    use tablepro_core::column::ColumnType;
    use tablepro_core::masking::stable_hash;

    use super::*;

    fn text(value: &str) -> tablepro_core::Value {
        tablepro_core::Value::Text(value.to_owned())
    }

    fn set(names: &[&str], rows: &[Vec<tablepro_core::Value>]) -> ResultSet {
        let columns: Arc<[ResultColumn]> = names
            .iter()
            .map(|name| ResultColumn::new(*name, ColumnType::untyped_text("text")))
            .collect::<Vec<_>>()
            .into();
        let store = Arc::new(ResultStore::new(columns));
        store.append(rows);
        store.finish();
        ResultSet::new(0, store)
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
    fn the_sheet_starts_from_what_the_detectors_see() {
        let people = set(
            &["id", "phone", "note"],
            &[vec![text("1"), text("x"), text("4111 1111 1111 1111")]],
        );

        let started = share_masking(&people, 3, 1_000);

        assert_eq!(started[0].suggestion, None);
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

    #[test]
    fn detection_reads_only_the_rows_a_share_sends() {
        let contacts = set(
            &["contact"],
            &[
                vec![text("ann@example.com")],
                vec![text("x")],
                vec![text("y")],
                vec![text("z")],
            ],
        );

        let sent_one = share_masking(&contacts, 1, 1);
        let sent_all = share_masking(&contacts, 1, 4);

        assert_eq!(
            sent_one[0].suggestion.as_ref().map(|found| found.style),
            Some(MaskStyleTag::Email)
        );
        assert_eq!(sent_all[0].suggestion, None, "rows past the share counted");
    }

    #[test]
    fn a_first_row_too_large_to_send_still_has_its_values_read() {
        let notes = set(
            &["blob", "notes"],
            &[
                vec![text(&"x".repeat(300 * 1_024)), text("ann@example.com")],
                vec![text("small"), text("bob@example.com")],
            ],
        );

        let started = share_masking(&notes, 2, 1_000);

        assert_eq!(
            started[1].suggestion.as_ref().map(|found| found.style),
            Some(MaskStyleTag::Email)
        );
    }

    #[test]
    fn values_in_rows_that_go_only_once_a_wide_column_is_removed_are_read() {
        // 22 rows fit the budget with the blob kept; the e-mails are in the 8 after them.
        let rows: Vec<Vec<tablepro_core::Value>> = (0..30)
            .map(|row| {
                let notes = match row < 22 {
                    true => tablepro_core::Value::Null,
                    false => text(&format!("person{row}@example.com")),
                };
                vec![text(&"x".repeat(200_000)), notes]
            })
            .collect();

        let started = share_masking(&set(&["blob", "notes"], &rows), 2, 1_000);

        assert_eq!(
            started[1].suggestion.as_ref().map(|found| found.style),
            Some(MaskStyleTag::Email)
        );
    }

    #[test]
    fn the_preview_shows_what_the_snapshot_sends() {
        let people = set(
            &["id", "email", "phone", "note"],
            &[
                vec![text("1"), text("ann@example.com"), text("+1 555 0100"), text("vip")],
                vec![text("2"), text("bob@example.com"), text("+1 555 0199"), text("new")],
            ],
        );
        let choices = [
            ShareColumnChoice::Remove,
            ShareColumnChoice::Mask {
                style: MaskStyleTag::Email,
            },
            ShareColumnChoice::Mask {
                style: MaskStyleTag::Hash,
            },
        ];

        let preview = share_preview(&people, 4, 1, &choices).unwrap();

        let names: Vec<String> = preview.columns().into_iter().map(|column| column.name).collect();
        assert_eq!(names, ["email", "phone", "note"]);
        assert_eq!(preview.row_count(), 1);
        assert!(preview.is_finished());
        assert_eq!(preview.cell_text(0, 0).unwrap().as_deref(), Some("a•••@example.com"));
        assert_eq!(preview.cell_text(0, 1).unwrap(), Some(stable_hash(b"+1 555 0100")));
        assert_eq!(preview.cell_text(0, 2).unwrap().as_deref(), Some("vip"));
    }
}
