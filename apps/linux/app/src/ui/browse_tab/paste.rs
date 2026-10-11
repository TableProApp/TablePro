use relm4::ComponentSender;
use relm4::gtk::{gdk, glib};

use super::value_parse::{TypeKind, classify_type, normalize_single_line_input, parse_input_for_grid_cell};
use super::*;

const MAX_PASTE_CELLS: usize = 5_000;

pub(super) fn parse_clipboard_grid(text: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut cell = String::new();
    let mut quoted = false;
    let mut was_quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' if quoted && chars.peek() == Some(&'"') => {
                cell.push('"');
                chars.next();
            }
            '"' if quoted => quoted = false,
            '"' if cell.is_empty() && !was_quoted => {
                quoted = true;
                was_quoted = true;
            }
            '\t' if !quoted => {
                row.push(std::mem::take(&mut cell));
                was_quoted = false;
            }
            '\r' if !quoted && chars.peek() == Some(&'\n') => {}
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

impl BrowseTab {
    pub(super) fn handle_paste(&mut self, row: u32, col: usize, sender: ComponentSender<Self>) {
        let Some(display) = gdk::Display::default() else {
            return;
        };
        let clipboard = display.clipboard();
        glib::spawn_future_local(async move {
            if let Ok(Some(text)) = clipboard.read_text_future().await {
                sender.input(BrowseTabInput::PasteText {
                    row,
                    col,
                    text: text.to_string(),
                });
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
        let text = match column.map(|column| classify_type(&column.data_type.to_ascii_lowercase())) {
            Some(TypeKind::Json) => cell.text.clone(),
            _ => normalize_single_line_input(&cell.text),
        };
        let current = row.as_ref().map(|row| row.cell_value(cell.col));
        parse_input_for_grid_cell(&text, column, &self.driver_id, current.as_ref())
            .map(|_| ())
            .map_err(|message| {
                crate::tr!("{column} on row {row}: {message}. Nothing was pasted.")
                    .replace("{column}", name)
                    .replace("{row}", &(cell.row + 1).to_string())
                    .replace("{message}", &message)
            })
    }

    pub(super) fn handle_paste_text(&mut self, row: u32, col: usize, text: &str, sender: ComponentSender<Self>) {
        let loaded = self.row_count_loaded();
        let cells = match paste_plan(
            row,
            col,
            &parse_clipboard_grid(text),
            loaded,
            self.current_columns.len(),
        ) {
            Ok(cells) => cells,
            Err(message) => {
                let _ = sender.output(BrowseTabOutput::ShowToast(message));
                return;
            }
        };
        if let Some(message) = cells.iter().find_map(|cell| self.check_paste_cell(cell).err()) {
            let _ = sender.output(BrowseTabOutput::ShowToast(message));
            return;
        }
        for cell in cells {
            self.handle_grid_cell_edited(cell.row, cell.col, cell.text, Vec::new(), sender.clone());
        }
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
}
