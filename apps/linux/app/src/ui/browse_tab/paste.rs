use relm4::ComponentSender;
use relm4::gtk::{self, gdk, glib};

use super::value_parse::parse_grid_cell_input;
use super::*;

const MAX_PASTE_CELLS: usize = 5_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::ui) struct PasteSnapshot {
    page_request_id: Option<uuid::Uuid>,
    row_keys: Vec<Option<crate::services::change_tracker::RowKey>>,
}

#[derive(Debug)]
pub(in crate::ui) struct PasteTextInput {
    pub(in crate::ui) row: u32,
    pub(in crate::ui) col: usize,
    pub(in crate::ui) row_key: Vec<Value>,
    pub(in crate::ui) text: String,
    pub(in crate::ui) snapshot: PasteSnapshot,
}

impl PasteSnapshot {
    fn new(
        page_request_id: Option<uuid::Uuid>,
        row_keys: Vec<Option<crate::services::change_tracker::RowKey>>,
    ) -> Self {
        Self {
            page_request_id,
            row_keys,
        }
    }

    fn matches(
        &self,
        current_page_request_id: Option<uuid::Uuid>,
        target_rows: &[u32],
        mut row_key_at: impl FnMut(u32) -> Option<crate::services::change_tracker::RowKey>,
    ) -> bool {
        if self.page_request_id != current_page_request_id {
            return false;
        }
        target_rows.iter().all(|row| {
            let Some(expected) = self.row_keys.get(*row as usize).and_then(Option::as_ref) else {
                return false;
            };
            row_key_at(*row).as_ref() == Some(expected)
        })
    }
}

fn is_spreadsheet_quoted_cell(after_open: &[char]) -> bool {
    let mut needs_quoting = false;
    let mut index = 0;
    while let Some(&c) = after_open.get(index) {
        index += 1;
        match c {
            '"' if after_open.get(index) == Some(&'"') => {
                needs_quoting = true;
                index += 1;
            }
            '"' => {
                let ends_cell = matches!(after_open.get(index), None | Some('\t' | '\n' | '\r'));
                return ends_cell && needs_quoting;
            }
            '\t' | '\n' | '\r' => needs_quoting = true,
            _ => {}
        }
    }
    false
}

pub(super) fn parse_clipboard_grid(text: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut cell = String::new();
    let mut quoted = false;
    let mut was_quoted = false;
    let chars: Vec<char> = text.chars().collect();
    let mut index = 0;
    while let Some(&c) = chars.get(index) {
        index += 1;
        match c {
            '"' if quoted && chars.get(index) == Some(&'"') => {
                cell.push('"');
                index += 1;
            }
            '"' if quoted => quoted = false,
            '"' if cell.is_empty() && !was_quoted && is_spreadsheet_quoted_cell(&chars[index..]) => {
                quoted = true;
                was_quoted = true;
            }
            '\t' if !quoted => {
                row.push(std::mem::take(&mut cell));
                was_quoted = false;
            }
            '\r' if !quoted && chars.get(index) == Some(&'\n') => {}
            '\n' if !quoted => {
                row.push(std::mem::take(&mut cell));
                rows.push(std::mem::take(&mut row));
                was_quoted = false;
            }
            _ => cell.push(c),
        }
    }
    if !cell.is_empty() || !row.is_empty() || was_quoted {
        row.push(cell);
        rows.push(row);
    }
    rows
}

#[derive(Debug, PartialEq, Eq)]
pub(super) struct PasteCell {
    pub(super) row: u32,
    pub(super) col: usize,
    pub(super) text: String,
}

pub(super) fn paste_plan(
    anchor_row: u32,
    anchor_col: usize,
    grid: &[Vec<String>],
    loaded_rows: u32,
    columns: usize,
) -> Result<Vec<PasteCell>, String> {
    let width = grid.iter().map(Vec::len).max().unwrap_or(0);
    let height = grid.len();
    if height == 0 || width == 0 {
        return Err(crate::tr!("The clipboard has no text to paste"));
    }
    if height.saturating_mul(width) > MAX_PASTE_CELLS {
        return Err(crate::tr!("That is too many cells to paste at once"));
    }
    if (anchor_row as usize).saturating_add(height) > loaded_rows as usize {
        return Err(crate::tr!("The pasted rows run past the last loaded row"));
    }
    if anchor_col.saturating_add(width) > columns {
        return Err(crate::tr!("The pasted columns run past the last column"));
    }
    let mut cells = Vec::with_capacity(height * width);
    for (r, line) in grid.iter().enumerate() {
        for (c, text) in line.iter().enumerate() {
            cells.push(PasteCell {
                row: anchor_row + r as u32,
                col: anchor_col + c,
                text: text.clone(),
            });
        }
    }
    Ok(cells)
}

pub(super) fn paste_shortcut(sender: ComponentSender<BrowseTab>) -> gtk::Shortcut {
    gtk::Shortcut::builder()
        .trigger(&crate::ui::shortcut::parse("<Primary>v"))
        .action(&gtk::CallbackAction::new(move |widget, _| {
            match crate::ui::grid::focused_cell_identity(widget).or_else(|| crate::ui::grid::last_clicked_cell(widget))
            {
                Some((row, col, row_key)) => sender.input(BrowseTabInput::Paste { row, col, row_key }),
                None => sender.input(BrowseTabInput::PasteNotSupported),
            }
            glib::Propagation::Stop
        }))
        .build()
}

impl BrowseTab {
    pub(super) fn handle_paste(&mut self, row: u32, col: usize, row_key: Vec<Value>, sender: ComponentSender<Self>) {
        if !self.row_position_still_holds(row, &row_key) {
            let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                "The rows changed since you clicked the cell, so nothing was pasted"
            )));
            return;
        }
        let Some(display) = gdk::Display::default() else {
            return;
        };
        let clipboard = display.clipboard();
        let snapshot = self.capture_paste_snapshot();
        glib::spawn_future_local(async move {
            if let Ok(Some(text)) = clipboard.read_text_future().await {
                sender.input(BrowseTabInput::PasteText(PasteTextInput {
                    row,
                    col,
                    row_key,
                    text: text.to_string(),
                    snapshot,
                }));
            }
        });
    }

    fn check_paste_cell(&self, cell: &PasteCell) -> Result<(), String> {
        let column = self.current_columns.get(cell.col);
        let row = self.row_object_at(cell.row);
        let allowed = column
            .zip(row.as_ref())
            .is_some_and(|(column, row)| crate::ui::grid::cell_allows_inline_edit(column, &row.cell_value(cell.col)));
        let name = column.map(|column| column.name.as_str()).unwrap_or_default();
        if !allowed {
            return Err(
                crate::tr!("{column} on row {row} can't be edited, so nothing was pasted")
                    .replace("{column}", name)
                    .replace("{row}", &(cell.row + 1).to_string()),
            );
        }
        let current = row.as_ref().map(|row| row.cell_value(cell.col));
        parse_grid_cell_input(&cell.text, column, &self.driver_id, current.as_ref())
            .map(|_| ())
            .map_err(|message| {
                crate::tr!("{column} on row {row}: {message}. Nothing was pasted.")
                    .replace("{column}", name)
                    .replace("{row}", &(cell.row + 1).to_string())
                    .replace("{message}", &message)
            })
    }

    pub(super) fn handle_paste_text(&mut self, input: PasteTextInput, sender: ComponentSender<Self>) {
        let PasteTextInput {
            row,
            col,
            row_key,
            text,
            snapshot,
        } = input;
        if snapshot.page_request_id != self.page_requests.current_id() || !self.row_position_still_holds(row, &row_key)
        {
            let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                "The rows changed since you clicked the cell, so nothing was pasted"
            )));
            return;
        }
        let loaded = self.row_count_loaded();
        let cells = match paste_plan(
            row,
            col,
            &parse_clipboard_grid(&text),
            loaded,
            self.current_columns.len(),
        ) {
            Ok(cells) => cells,
            Err(message) => {
                let _ = sender.output(BrowseTabOutput::ShowToast(message));
                return;
            }
        };
        let target_rows: Vec<u32> = cells.iter().map(|cell| cell.row).collect();
        if !snapshot.matches(self.page_requests.current_id(), &target_rows, |position| {
            self.paste_row_key_at(position)
        }) {
            let _ = sender.output(BrowseTabOutput::ShowToast(crate::tr!(
                "That row moved while you were editing. The change was not applied."
            )));
            return;
        }
        if let Some(message) = cells.iter().find_map(|cell| self.check_paste_cell(cell).err()) {
            let _ = sender.output(BrowseTabOutput::ShowToast(message));
            return;
        }
        for cell in cells {
            self.handle_grid_cell_edited(cell.row, cell.col, cell.text, Vec::new(), sender.clone());
        }
    }

    fn capture_paste_snapshot(&self) -> PasteSnapshot {
        let row_keys = (0..self.row_count_loaded())
            .map(|position| self.paste_row_key_at(position))
            .collect();
        PasteSnapshot::new(self.page_requests.current_id(), row_keys)
    }

    fn paste_row_key_at(&self, position: u32) -> Option<crate::services::change_tracker::RowKey> {
        let row = self.row_object_at(position)?;
        if let Some(draft_id) = row.draft_id() {
            return Some(crate::services::change_tracker::RowKey::Draft(draft_id));
        }
        self.row_key_at(position).map(|(key, _)| key)
    }

    fn row_count_loaded(&self) -> u32 {
        self.current_selection
            .as_ref()
            .map_or(0, |selection| selection.n_items())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grid(rows: &[&[&str]]) -> Vec<Vec<String>> {
        rows.iter()
            .map(|row| row.iter().map(|cell| cell.to_string()).collect())
            .collect()
    }

    #[test]
    fn tab_separated_text_becomes_rows_and_cells() {
        assert_eq!(parse_clipboard_grid("a\tb\nc\td\n"), grid(&[&["a", "b"], &["c", "d"]]));
        assert_eq!(parse_clipboard_grid("a\tb\r\nc\td"), grid(&[&["a", "b"], &["c", "d"]]));
        assert_eq!(parse_clipboard_grid("only"), grid(&[&["only"]]));
        assert!(parse_clipboard_grid("").is_empty());
    }

    #[test]
    fn spreadsheet_quoting_keeps_tabs_newlines_and_quotes_inside_one_cell() {
        assert_eq!(
            parse_clipboard_grid("\"a\tb\"\t\"line1\nline2\"\t\"say \"\"hi\"\"\"\n"),
            grid(&[&["a\tb", "line1\nline2", "say \"hi\""]])
        );
        assert_eq!(parse_clipboard_grid("x\t\ty\n"), grid(&[&["x", "", "y"]]));
        assert_eq!(parse_clipboard_grid("a\"b\tc"), grid(&[&["a\"b", "c"]]));
    }

    #[test]
    fn a_leading_quote_on_ordinary_text_is_kept() {
        assert_eq!(parse_clipboard_grid("\"abc\""), grid(&[&["\"abc\""]]));
        assert_eq!(parse_clipboard_grid("\"a\", \"b\"\tx"), grid(&[&["\"a\", \"b\"", "x"]]));
        assert_eq!(parse_clipboard_grid("\"abc\tdef"), grid(&[&["\"abc", "def"]]));
        assert_eq!(parse_clipboard_grid("\"\"\n\"x\""), grid(&[&["\"\""], &["\"x\""]]));
        assert_eq!(parse_clipboard_grid("\"a\tb\"x"), grid(&[&["\"a", "b\"x"]]));
    }

    #[test]
    fn a_plan_places_every_cell_from_the_anchor_and_refuses_to_run_off_the_grid() {
        let plan = paste_plan(2, 1, &grid(&[&["a", "b"], &["c", "d"]]), 10, 5).unwrap();
        let places: Vec<(u32, usize, &str)> = plan.iter().map(|c| (c.row, c.col, c.text.as_str())).collect();
        assert_eq!(places, [(2, 1, "a"), (2, 2, "b"), (3, 1, "c"), (3, 2, "d")]);
        assert!(paste_plan(9, 0, &grid(&[&["a"], &["b"]]), 10, 5).is_err());
        assert!(paste_plan(0, 4, &grid(&[&["a", "b"]]), 10, 5).is_err());
        assert!(paste_plan(0, 0, &[], 10, 5).is_err());
    }

    #[test]
    fn a_huge_paste_is_refused_before_any_cell_is_touched() {
        let big = vec![vec!["x".to_string(); 100]; 100];
        assert!(paste_plan(0, 0, &big, 20_000, 200).is_err());
    }

    #[test]
    fn a_pending_paste_requires_the_same_page_generation_and_target_row_identities() {
        use crate::services::change_tracker::RowKey;
        use tablepro_core::Value;

        let first = RowKey::from_pk_values(&[Value::Int(1)]).unwrap();
        let second = RowKey::from_pk_values(&[Value::Int(2)]).unwrap();
        let draft = RowKey::Draft(7);
        let generation = uuid::Uuid::new_v4();
        let snapshot = PasteSnapshot::new(
            Some(generation),
            vec![Some(first.clone()), Some(second.clone()), Some(draft.clone())],
        );
        let unchanged = [Some(first.clone()), Some(second.clone()), Some(draft.clone())];
        let reordered = [Some(second.clone()), Some(first.clone()), Some(draft.clone())];
        let replaced_draft = [Some(first.clone()), Some(second.clone()), Some(RowKey::Draft(8))];
        let missing = [Some(first.clone()), None, Some(draft)];

        assert!(snapshot.matches(Some(generation), &[0, 1, 2], |position| {
            unchanged[position as usize].clone()
        }));
        assert!(!snapshot.matches(Some(uuid::Uuid::new_v4()), &[0], |position| {
            unchanged[position as usize].clone()
        }));
        assert!(!snapshot.matches(Some(generation), &[0, 1], |position| {
            reordered[position as usize].clone()
        }));
        assert!(!snapshot.matches(Some(generation), &[2], |position| {
            replaced_draft[position as usize].clone()
        }));
        assert!(!snapshot.matches(Some(generation), &[0, 1], |position| missing[position as usize].clone()));
    }
}

#[cfg(test)]
mod roundtrip_tests {
    use super::parse_clipboard_grid;

    fn spreadsheet_encode(rows: &[Vec<String>]) -> String {
        rows.iter()
            .map(|row| {
                row.iter()
                    .map(|cell| {
                        if cell.contains(['\t', '\n', '\r', '"']) {
                            format!("\"{}\"", cell.replace('"', "\"\""))
                        } else {
                            cell.clone()
                        }
                    })
                    .collect::<Vec<_>>()
                    .join("\t")
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn strings(alphabet: &[char], max_len: usize) -> Vec<String> {
        let mut all = vec![String::new()];
        let mut frontier = vec![String::new()];
        for _ in 0..max_len {
            frontier = frontier
                .iter()
                .flat_map(|prefix| alphabet.iter().map(move |c| format!("{prefix}{c}")))
                .collect();
            all.extend(frontier.iter().cloned());
        }
        all
    }

    #[test]
    fn whatever_a_spreadsheet_copies_is_pasted_back_unchanged() {
        let cells = strings(&['a', '"', '\t', '\n', ' '], 3);
        let mut failures = Vec::new();
        for first in &cells {
            for second in &cells {
                let grid = vec![vec![first.clone(), second.clone()]];
                let text = spreadsheet_encode(&grid);
                if text.is_empty() {
                    continue;
                }
                let parsed = parse_clipboard_grid(&text);
                if parsed != grid {
                    failures.push((grid, text, parsed));
                }
            }
        }
        assert!(
            failures.is_empty(),
            "{} of {} copies changed; first: {:?}",
            failures.len(),
            cells.len() * cells.len(),
            failures.first()
        );
    }
    #[test]
    fn carriage_returns_and_several_rows_survive_the_same_round_trip() {
        let with_returns = strings(&['a', '"', '\t', '\n', '\r', ' '], 2);
        for first in &with_returns {
            for second in &with_returns {
                let grid = vec![vec![first.clone(), second.clone()]];
                let text = spreadsheet_encode(&grid);
                if !text.is_empty() {
                    assert_eq!(parse_clipboard_grid(&text), grid, "{text:?}");
                }
            }
        }
        let small = strings(&['a', '"', '\t', '\n', '\r', ' '], 1);
        for a in &small {
            for b in &small {
                for c in &small {
                    for d in &small {
                        let grid = vec![vec![a.clone(), b.clone()], vec![c.clone(), d.clone()]];
                        let text = spreadsheet_encode(&grid);
                        assert_eq!(parse_clipboard_grid(&text), grid, "{text:?}");
                    }
                }
            }
        }
    }
}
