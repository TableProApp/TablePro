use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};

use serde::{Deserialize, Serialize};

/// A table's saved column order, hidden columns and widths, all by
/// column name so they survive a column added or dropped on the server.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ColumnLayout {
    #[serde(default)]
    pub order: Vec<LayoutSlot>,
    #[serde(default)]
    pub hidden: BTreeSet<String>,
    #[serde(default)]
    pub widths: BTreeMap<String, i32>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(tag = "kind", content = "name", rename_all = "snake_case")]
pub enum LayoutSlot {
    RowNumbers,
    Column(String),
}

/// One column of the grid in display order.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    RowNumbers,
    Column {
        index: usize,
        visible: bool,
        width: Option<i32>,
    },
}

impl ColumnLayout {
    /// `names` are the result's columns in result order. Saved slots come
    /// first, then columns the layout has not seen, in result order.
    pub fn arrange(&self, names: &[&str]) -> Vec<Placement> {
        let mut unplaced: HashMap<&str, VecDeque<usize>> = HashMap::new();
        for (index, name) in names.iter().enumerate() {
            unplaced.entry(name).or_default().push_back(index);
        }
        let mut placed = vec![false; names.len()];
        let mut placements = Vec::with_capacity(names.len() + 1);
        let mut row_numbers = false;
        for slot in &self.order {
            match slot {
                LayoutSlot::RowNumbers if !row_numbers => {
                    row_numbers = true;
                    placements.push(Placement::RowNumbers);
                }
                LayoutSlot::RowNumbers => {}
                LayoutSlot::Column(name) => {
                    if let Some(index) = unplaced.get_mut(name.as_str()).and_then(VecDeque::pop_front) {
                        placed[index] = true;
                        placements.push(self.placement(index, name));
                    }
                }
            }
        }
        for (index, name) in names.iter().enumerate() {
            if !placed[index] {
                placements.push(self.placement(index, name));
            }
        }
        if !row_numbers {
            placements.insert(0, Placement::RowNumbers);
        }
        show_one(&mut placements);
        placements
    }

    pub fn with_order(&self, slots: Vec<LayoutSlot>) -> Self {
        Self {
            order: slots,
            ..self.clone()
        }
    }

    pub fn with_hidden(&self, name: &str, hidden: bool) -> Self {
        let mut layout = self.clone();
        if hidden {
            layout.hidden.insert(name.to_owned());
        } else {
            layout.hidden.remove(name);
        }
        layout
    }

    pub fn with_width(&self, name: &str, width: i32) -> Self {
        let mut layout = self.clone();
        layout.widths.insert(name.to_owned(), width);
        layout
    }

    pub fn without_width(&self, name: &str) -> Self {
        let mut layout = self.clone();
        layout.widths.remove(name);
        layout
    }

    /// What changed from `before` to this layout, laid onto `latest`: a
    /// grid on the same table in another tab may have saved since.
    pub fn rebased(&self, before: &ColumnLayout, latest: &ColumnLayout) -> ColumnLayout {
        let mut merged = latest.clone();
        for name in before.hidden.symmetric_difference(&self.hidden) {
            match self.hidden.contains(name) {
                true => merged.hidden.insert(name.clone()),
                false => merged.hidden.remove(name),
            };
        }
        for name in before.widths.keys().chain(self.widths.keys()) {
            if before.widths.get(name) == self.widths.get(name) {
                continue;
            }
            match self.widths.get(name) {
                Some(width) => merged.widths.insert(name.clone(), *width),
                None => merged.widths.remove(name),
            };
        }
        if self.order != before.order {
            merged.order = merge_order(&latest.order, self.order.clone());
        }
        merged
    }

    fn placement(&self, index: usize, name: &str) -> Placement {
        Placement::Column {
            index,
            visible: !self.hidden.contains(name),
            width: self.widths.get(name).copied(),
        }
    }
}

/// The shown slots in their new order, with each slot the view lacks put
/// back after the slot it followed before.
pub fn merge_order(stored: &[LayoutSlot], shown: Vec<LayoutSlot>) -> Vec<LayoutSlot> {
    let mut merged = shown;
    let mut previous: Option<LayoutSlot> = None;
    for slot in stored {
        if !merged.contains(slot) {
            let at = previous
                .as_ref()
                .and_then(|previous| merged.iter().position(|slot| slot == previous))
                .map_or(merged.len(), |position| position + 1);
            merged.insert(at, slot.clone());
        }
        previous = Some(slot.clone());
    }
    merged
}

/// A grid of no columns has nothing to focus and no header to bring one
/// back from, so when the columns a layout kept shown are gone the first
/// column on screen shows.
fn show_one(placements: &mut [Placement]) {
    if placements
        .iter()
        .any(|placement| matches!(placement, Placement::Column { visible: true, .. }))
    {
        return;
    }
    if let Some(Placement::Column { visible, .. }) = placements
        .iter_mut()
        .find(|placement| matches!(placement, Placement::Column { .. }))
    {
        *visible = true;
    }
}

#[cfg(test)]
mod tests {
    use super::{ColumnLayout, LayoutSlot, Placement};

    fn shown(index: usize) -> Placement {
        Placement::Column {
            index,
            visible: true,
            width: None,
        }
    }

    fn column(name: &str) -> LayoutSlot {
        LayoutSlot::Column(name.to_owned())
    }

    #[test]
    fn an_empty_layout_shows_every_column_in_result_order() {
        assert_eq!(
            ColumnLayout::default().arrange(&["id", "name"]),
            vec![Placement::RowNumbers, shown(0), shown(1)]
        );
        assert_eq!(ColumnLayout::default().arrange(&[]), vec![Placement::RowNumbers]);
    }

    #[test]
    fn renamed_and_dropped_columns_fall_out_and_new_ones_append() {
        let layout = ColumnLayout::default().with_order(vec![
            LayoutSlot::RowNumbers,
            column("email"),
            column("gone"),
            column("id"),
        ]);

        assert_eq!(
            layout.arrange(&["id", "full_name", "email", "added"]),
            vec![Placement::RowNumbers, shown(2), shown(0), shown(1), shown(3)]
        );
    }

    #[test]
    fn a_change_lands_on_what_another_grid_saved_since() {
        let before = ColumnLayout::default().with_width("id", 60);
        let latest = before.with_width("name", 240).with_hidden("email", true);
        let mine = before.with_width("id", 90).with_hidden("note", true);

        let saved = mine.rebased(&before, &latest);

        assert_eq!(
            saved,
            latest.with_width("id", 90).with_hidden("note", true),
            "the other grid's width and hidden column were lost"
        );
        assert_eq!(
            before.rebased(&before, &latest),
            latest,
            "no change of mine wrote over theirs"
        );
    }

    #[test]
    fn a_reorder_keeps_the_columns_only_the_saved_layout_knows() {
        let before = ColumnLayout::default().with_order(vec![LayoutSlot::RowNumbers, column("a"), column("b")]);
        let latest = before.with_order(vec![LayoutSlot::RowNumbers, column("a"), column("gone"), column("b")]);
        let mine = before.with_order(vec![LayoutSlot::RowNumbers, column("b"), column("a")]);

        assert_eq!(
            mine.rebased(&before, &latest).order,
            [LayoutSlot::RowNumbers, column("b"), column("a"), column("gone")]
        );
    }

    #[test]
    fn hidden_columns_and_widths_follow_the_name() {
        let layout = ColumnLayout::default()
            .with_hidden("secret", true)
            .with_width("name", 240)
            .with_width("id", 60)
            .without_width("id");

        assert_eq!(
            layout.arrange(&["id", "name", "secret"]),
            vec![
                Placement::RowNumbers,
                shown(0),
                Placement::Column {
                    index: 1,
                    visible: true,
                    width: Some(240),
                },
                Placement::Column {
                    index: 2,
                    visible: false,
                    width: None,
                },
            ]
        );
        assert_eq!(layout.with_hidden("secret", false).hidden.len(), 0);
    }

    #[test]
    fn a_layout_whose_shown_columns_are_gone_shows_the_first_column() {
        let layout = ColumnLayout::default().with_hidden("a", true).with_hidden("b", true);

        assert_eq!(
            layout.arrange(&["a", "b"]),
            vec![
                Placement::RowNumbers,
                shown(0),
                Placement::Column {
                    index: 1,
                    visible: false,
                    width: None,
                },
            ]
        );
    }

    #[test]
    fn duplicate_names_take_the_first_unplaced_column() {
        let layout = ColumnLayout::default().with_order(vec![column("n"), LayoutSlot::RowNumbers, column("n")]);

        assert_eq!(
            layout.arrange(&["n", "x", "n"]),
            vec![shown(0), Placement::RowNumbers, shown(2), shown(1)]
        );
    }

    #[test]
    fn the_row_number_slot_moves_and_is_placed_once() {
        let moved =
            ColumnLayout::default().with_order(vec![column("b"), LayoutSlot::RowNumbers, LayoutSlot::RowNumbers]);

        assert_eq!(
            moved.arrange(&["a", "b"]),
            vec![shown(1), Placement::RowNumbers, shown(0)]
        );
        let without = ColumnLayout::default().with_order(vec![column("b")]);
        assert_eq!(
            without.arrange(&["a", "b"]),
            vec![Placement::RowNumbers, shown(1), shown(0)]
        );
    }

    #[test]
    fn a_layout_reads_back_from_its_json() {
        let layout = ColumnLayout::default()
            .with_order(vec![LayoutSlot::RowNumbers, column("id")])
            .with_hidden("note", true)
            .with_width("id", 80);

        let json = serde_json::to_string(&layout).expect("serialised");

        assert_eq!(
            json,
            r#"{"order":[{"kind":"row_numbers"},{"kind":"column","name":"id"}],"hidden":["note"],"widths":{"id":80}}"#
        );
        assert_eq!(serde_json::from_str::<ColumnLayout>(&json).expect("parsed"), layout);
        assert_eq!(
            serde_json::from_str::<ColumnLayout>("{}").expect("parsed"),
            ColumnLayout::default()
        );
    }
}
