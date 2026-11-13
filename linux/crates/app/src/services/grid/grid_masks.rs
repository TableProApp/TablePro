use std::sync::Arc;

use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::masking::{ColumnMasks, MaskingPolicy, MaskingStyle, SharedMaskingPolicy, mask_value, table_name};
use tablepro_core::meta::TableRef;

// How a grid's columns meet the connection's masking rules, by column index (core ADR 0026).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GridMasks {
    // How the held cells are masked: a value under a mask is gone.
    pub shown: ColumnMasks,
    // What every path out of the app masks each column with, also for a tab the user revealed.
    pub external: ColumnMasks,
    // The tab shows its rows unmasked.
    pub revealed: bool,
    // A column of the key that names the rows is masked, so no row can be named to the server.
    pub masked_key: bool,
    // The columns `external` masks only because nothing traced them to a table column.
    pub untraced: Vec<usize>,
}

impl GridMasks {
    pub fn none() -> Self {
        Self::default()
    }

    pub fn is_masked(&self, column: usize) -> bool {
        self.shown.is_masked(column)
    }

    // What an export or a share lays over the held cells, for the columns at `indices`, in that order.
    pub fn outward(&self, indices: &[usize]) -> ColumnMasks {
        let overlay = self.shown.overlay(&self.external);
        ColumnMasks::new(indices.iter().map(|index| overlay.style(*index)).collect())
    }

    // Each column at `indices` as the held cells show it, in that order.
    pub fn shown_at(&self, indices: &[usize]) -> ColumnMasks {
        ColumnMasks::new(indices.iter().map(|index| self.shown.style(*index)).collect())
    }

    // The rules each column at `indices` meets on the way out.
    pub fn external_at(&self, indices: &[usize]) -> ColumnMasks {
        ColumnMasks::new(indices.iter().map(|index| self.external.style(*index)).collect())
    }

    // Where among the columns at `indices` an untraced one sits.
    pub fn untraced_at(&self, indices: &[usize]) -> Vec<usize> {
        indices
            .iter()
            .enumerate()
            .filter(|(_, index)| self.untraced.contains(index))
            .map(|(position, _)| position)
            .collect()
    }

    // A revealed tab offers nothing more to reveal.
    pub fn revealable(&self) -> bool {
        !self.revealed && !self.shown.is_empty()
    }
}

// Where a grid's rows come from, which decides how the rules meet them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MaskSource {
    // The app's own read of one table: the grid and every path out match by the table.
    Table(String),
    // The user's statement: the grid by the table it reads when known, every path out by what each column reads.
    Query { table: Option<String> },
    // A key-value engine's key, read by the app: by name alone.
    Key,
}

impl MaskSource {
    // The masks for `columns` under `policy`. A revealed tab's held cells are not masked, and every path out still is.
    pub fn masks(&self, policy: &MaskingPolicy, columns: &[ResultColumn], revealed: bool) -> GridMasks {
        let (grid, external, untraced) = match self {
            Self::Table(table) => (
                policy.column_masks(Some(table), columns),
                policy.external_column_masks(Some(table), columns),
                policy.untraced_columns(Some(table), columns),
            ),
            Self::Query { table } => (
                policy.column_masks(table.as_deref(), columns),
                policy.external_column_masks(None, columns),
                policy.untraced_columns(None, columns),
            ),
            Self::Key => {
                let masks = policy.column_masks(None, columns);
                (masks.clone(), masks, Vec::new())
            }
        };
        GridMasks {
            shown: if revealed { ColumnMasks::none() } else { grid },
            external,
            revealed,
            masked_key: false,
            untraced,
        }
    }
}

// The masks a grid's columns take under rules, worked out again at each use; the table is the grid's own when it has one.
pub type OutwardMasks = Arc<dyn Fn(&MaskingPolicy, &[ResultColumn], Option<&TableRef>) -> GridMasks + Send + Sync>;

// The session's live rules and how a grid's columns meet them, so an export or a share reads the rules as they are
// when it runs, never a remask still on its way.
#[derive(Clone)]
pub struct OutwardRules {
    pub rules: SharedMaskingPolicy,
    pub masks: OutwardMasks,
}

impl OutwardRules {
    pub fn new(rules: SharedMaskingPolicy, masks: OutwardMasks) -> Self {
        Self { rules, masks }
    }

    // A table's own read: the grid's table and columns, by name.
    pub fn table(rules: SharedMaskingPolicy) -> Self {
        Self::new(
            rules,
            Arc::new(
                |policy: &MaskingPolicy, columns: &[ResultColumn], table: Option<&TableRef>| {
                    MaskSource::Table(table.map(table_name).unwrap_or_default()).masks(policy, columns, false)
                },
            ),
        )
    }

    // The generation first, so rules set between the reads are read again next time.
    pub fn now(&self, columns: &[ResultColumn], table: Option<&TableRef>) -> (u64, GridMasks) {
        let generation = self.rules.generation();
        (generation, (self.masks)(&self.rules.get(), columns, table))
    }
}

impl std::fmt::Debug for OutwardRules {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OutwardRules").finish_non_exhaustive()
    }
}

// After a saved change: a column already masked keeps its mask, since the value under it is gone.
pub fn remask_rows(
    columns: &[ResultColumn],
    held: &ColumnMasks,
    fresh: &ColumnMasks,
    rows: &[Arc<[Value]>],
) -> Option<(ColumnMasks, Vec<Arc<[Value]>>)> {
    let added: Vec<(usize, MaskingStyle)> = fresh
        .masked_columns()
        .filter(|(index, _)| *index < columns.len() && !held.is_masked(*index))
        .collect();
    if added.is_empty() {
        return None;
    }
    let mut styles: Vec<Option<MaskingStyle>> = (0..columns.len()).map(|index| held.style(index)).collect();
    for (index, style) in &added {
        styles[*index] = Some(*style);
    }
    let rows = rows
        .iter()
        .map(|row| {
            let mut cells = row.to_vec();
            for (index, style) in &added {
                if let Some(cell) = cells.get_mut(*index) {
                    *cell = mask_value(cell, &columns[*index].column_type, *style);
                }
            }
            Arc::from(cells)
        })
        .collect();
    Some((ColumnMasks::new(styles), rows))
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnOrigin, ColumnType};
    use tablepro_core::masking::{MaskingRule, MaskingTarget};
    use tablepro_core::meta::TableRef;

    use super::*;

    fn email_rule() -> MaskingPolicy {
        MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )])
    }

    fn column(name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("text"))
    }

    fn traced(name: &str, source: &str) -> ResultColumn {
        column(name).with_origin(Some(ColumnOrigin::new(TableRef::unqualified("users"), source)))
    }

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    #[test]
    fn a_table_tab_masks_by_its_table_and_a_revealed_one_only_on_the_way_out() {
        let columns = [column("id"), column("email")];

        let masked = MaskSource::Table("public.users".to_owned()).masks(&email_rule(), &columns, false);
        let revealed = MaskSource::Table("public.users".to_owned()).masks(&email_rule(), &columns, true);

        assert_eq!(masked.shown.styles(), [None, Some(MaskingStyle::Email)]);
        assert!(masked.revealable());
        assert!(revealed.shown.is_empty());
        assert!(!revealed.revealable());
        assert_eq!(revealed.outward(&[0, 1]).styles(), [None, Some(MaskingStyle::Email)]);
    }

    #[test]
    fn a_query_masks_an_alias_on_screen_by_name_and_outward_by_origin() {
        let columns = [traced("id", "id"), traced("contact", "email"), column("total")];

        let masks = MaskSource::Query {
            table: Some("users".to_owned()),
        }
        .masks(&email_rule(), &columns, false);

        assert_eq!(masks.shown.styles(), [None, None, None]);
        assert_eq!(
            masks.outward(&[1, 2, 0]).styles(),
            [Some(MaskingStyle::Email), Some(MaskingStyle::Full), None]
        );
        assert_eq!(masks.untraced, [2]);
        assert_eq!(masks.untraced_at(&[2, 0]), [0]);
    }

    #[test]
    fn a_saved_rule_masks_held_rows_once_and_leaves_masked_columns_alone() {
        let columns = [column("email"), column("phone")];
        let held = ColumnMasks::new(vec![None, Some(MaskingStyle::Full)]);
        let fresh = ColumnMasks::new(vec![Some(MaskingStyle::Email), Some(MaskingStyle::LastFour)]);
        let rows: Vec<Arc<[Value]>> = vec![Arc::from(vec![text("ann@example.com"), text("••••")])];

        let (masks, rows) = remask_rows(&columns, &held, &fresh, &rows).expect("a change");

        assert_eq!(masks.styles(), [Some(MaskingStyle::Email), Some(MaskingStyle::Full)]);
        assert_eq!(&*rows[0], [text("a•••@example.com"), text("••••")]);
        assert_eq!(remask_rows(&columns, &masks, &fresh, &rows), None);
    }
}
