use super::{MaskingStyle, mask_value};
use crate::column::ResultColumn;
use crate::value::Value;

// Which columns of one result are masked, and how, by position. Every surface masks rows through this.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ColumnMasks {
    styles: Vec<Option<MaskingStyle>>,
}

impl ColumnMasks {
    pub fn new(styles: Vec<Option<MaskingStyle>>) -> Self {
        Self { styles }
    }

    pub fn none() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.styles.iter().all(Option::is_none)
    }

    pub fn styles(&self) -> &[Option<MaskingStyle>] {
        &self.styles
    }

    pub fn style(&self, column: usize) -> Option<MaskingStyle> {
        self.styles.get(column).copied().flatten()
    }

    pub fn is_masked(&self, column: usize) -> bool {
        self.style(column).is_some()
    }

    pub fn masked_columns(&self) -> impl Iterator<Item = (usize, MaskingStyle)> + '_ {
        self.styles
            .iter()
            .enumerate()
            .filter_map(|(column, style)| style.map(|style| (column, style)))
    }

    // Only the first `count` columns, as a table page's row addresses after its visible columns are never masked.
    #[must_use]
    pub fn first(mut self, count: usize) -> Self {
        self.styles.truncate(count);
        self
    }

    // `columns` is the result's, for each cell's text form. A row shorter than the masks leaves the rest alone.
    pub fn apply(&self, columns: &[ResultColumn], row: &mut [Value]) {
        for (index, style) in self.masked_columns() {
            let (Some(cell), Some(column)) = (row.get_mut(index), columns.get(index)) else {
                continue;
            };
            *cell = mask_value(cell, &column.column_type, style);
        }
    }

    pub fn apply_rows(&self, columns: &[ResultColumn], rows: &mut [Vec<Value>]) {
        if self.is_empty() {
            return;
        }
        for row in rows {
            self.apply(columns, row);
        }
    }

    // What to lay over values already masked as `self` for a reader outside the grid, `external` being that path's
    // masks. A column the grid masked the same way stays as it is; one masked another way takes the stricter style,
    // over what the grid already hid.
    pub fn overlay(&self, external: &Self) -> Self {
        Self {
            styles: external
                .styles
                .iter()
                .enumerate()
                .map(|(column, style)| {
                    let shown = self.style(column);
                    match *style == shown {
                        true => None,
                        false => style.and_then(|style| MaskingStyle::strictest(shown, Some(style))),
                    }
                })
                .collect(),
        }
    }

    // Each column's mask once `overlay` is laid over values already masked as `self`.
    #[must_use]
    pub fn merged(&self, overlay: &Self) -> Self {
        let width = self.styles.len().max(overlay.styles.len());
        Self {
            styles: (0..width)
                .map(|column| overlay.style(column).or_else(|| self.style(column)))
                .collect(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::MaskingStyle::{Email, Full, Hash, LastFour, Null};
    use super::*;
    use crate::column::ColumnType;

    fn columns(count: usize) -> Vec<ResultColumn> {
        (0..count)
            .map(|index| ResultColumn::new(format!("c{index}"), ColumnType::untyped_text("text")))
            .collect()
    }

    #[test]
    fn a_row_takes_each_column_s_style_and_leaves_the_rest() {
        let masks = ColumnMasks::new(vec![None, Some(LastFour), Some(Null)]);
        let mut row = vec![
            Value::Text("ann".to_owned()),
            Value::Text("555-0100".to_owned()),
            Value::Text("x".to_owned()),
            Value::Text("past the masks".to_owned()),
        ];

        masks.apply(&columns(4), &mut row);

        assert_eq!(
            row,
            [
                Value::Text("ann".to_owned()),
                Value::Text("••••0100".to_owned()),
                Value::Null,
                Value::Text("past the masks".to_owned()),
            ]
        );
    }

    #[test]
    fn a_short_row_is_masked_as_far_as_it_goes() {
        let masks = ColumnMasks::new(vec![Some(Full), Some(Full)]);
        let mut row = vec![Value::Text("a".to_owned())];

        masks.apply(&columns(2), &mut row);

        assert_eq!(row, [Value::Text("••••".to_owned())]);
    }

    #[test]
    fn the_overlay_skips_what_the_grid_masked_the_same_way_and_tightens_the_rest() {
        let shown = ColumnMasks::new(vec![Some(Email), Some(Hash), None, Some(Full)]);
        let external = ColumnMasks::new(vec![Some(Email), Some(LastFour), Some(Hash), None]);

        let overlay = shown.overlay(&external);

        assert_eq!(overlay.styles(), [None, Some(Full), Some(Hash), None]);
        assert_eq!(
            shown.merged(&overlay).styles(),
            [Some(Email), Some(Full), Some(Hash), Some(Full)]
        );
    }

    #[test]
    fn row_addresses_past_the_visible_columns_are_left_unmasked() {
        let masks = ColumnMasks::new(vec![Some(Full), None, Some(Full)]).first(2);

        assert_eq!(masks.styles(), [Some(Full), None]);
        assert!(!masks.is_masked(2));
    }
}
