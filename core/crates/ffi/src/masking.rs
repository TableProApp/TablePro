// Masking for the Windows app: a connection's rules, the grid's masked columns, the share sheet's column choices and
// what the detectors suggest. The engine is `tablepro_core::masking` (core ADR 0026).

use std::sync::Arc;

use tablepro_core::column::ResultColumn;
use tablepro_core::masking::detect::{
    MaskSuggestion, PersonalDataHit, SensitiveKind, SuggestionReason, scan_sql_personal_data, suggest_masks,
};
use tablepro_core::masking::{MaskingRule, MaskingStyle, MaskingTarget};
use uuid::Uuid;

use crate::error::CoreError;
use crate::export::held_row;
use crate::results::ResultSet;
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

// One shared column as the sheet starts it: `rule` is the style the connection's rules mask it with on the way out,
// which can never be Keep; otherwise `suggestion` is what the detectors saw, masked by default.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareColumnMasking {
    pub name: String,
    pub rule: Option<MaskStyleTag>,
    pub suggestion: Option<MaskSuggestionInfo>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct PersonalDataHitInfo {
    pub kind: SensitiveKindTag,
    // Where the literal starts, from 1.
    pub line: u32,
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

fn share_masking(set: &ResultSet, visible_columns: u32, max_rows: u32) -> Vec<ShareColumnMasking> {
    let held = set.result_columns();
    let visible = usize::try_from(visible_columns).unwrap_or(usize::MAX).min(held.len());
    let columns: Vec<ResultColumn> = held[..visible].to_vec();
    let rules = set.external_masks(&columns);
    let rows: Vec<Vec<tablepro_core::Value>> = (0..set.row_count().min(u64::from(max_rows)))
        .map(|row| held_row(set, row, &columns))
        .collect();
    suggest_masks(&columns, &rows, &rules)
        .into_iter()
        .zip(&columns)
        .enumerate()
        .map(|(index, (suggestion, column))| ShareColumnMasking {
            name: column.name.clone(),
            rule: rules.style(index).map(MaskStyleTag::from),
            suggestion: suggestion.map(MaskSuggestionInfo::from),
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

// The style a shared column leaves with: never less than the rule's, and Remove is not a style.
pub(crate) fn chosen_style(choice: ShareColumnChoice, rule: Option<MaskingStyle>) -> Option<MaskingStyle> {
    let wanted = match choice {
        ShareColumnChoice::Keep | ShareColumnChoice::Remove => None,
        ShareColumnChoice::Mask { style } => Some(style.into()),
    };
    MaskingStyle::strictest(rule, wanted)
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
    fn a_rule_masked_column_never_leaves_weaker_than_its_rule() {
        let email = Some(MaskingStyle::Email);
        let mask = |style| ShareColumnChoice::Mask { style };

        assert_eq!(chosen_style(ShareColumnChoice::Keep, email), email);
        assert_eq!(chosen_style(mask(MaskStyleTag::Email), email), email);
        assert_eq!(
            chosen_style(mask(MaskStyleTag::LastFour), email),
            Some(MaskingStyle::Full)
        );
        assert_eq!(chosen_style(mask(MaskStyleTag::Null), email), Some(MaskingStyle::Null));
        assert_eq!(chosen_style(ShareColumnChoice::Keep, None), None);
        assert_eq!(chosen_style(mask(MaskStyleTag::Hash), None), Some(MaskingStyle::Hash));
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
}
