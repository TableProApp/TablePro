use relm4::gtk;
use relm4::gtk::prelude::*;

pub(crate) fn text_to_run(buffer: &gtk::TextBuffer) -> String {
    if let Some((start, end)) = buffer.selection_bounds() {
        let selected = buffer.text(&start, &end, true).to_string();
        if !selected.trim().is_empty() {
            return selected;
        }
    }
    let (start, end) = buffer.bounds();
    buffer.text(&start, &end, true).to_string()
}

pub(crate) fn toggle_line_comment(buffer: &gtk::TextBuffer) {
    let (sel_start, sel_end) = buffer.selection_bounds().unwrap_or_else(|| {
        let i = buffer.iter_at_mark(&buffer.get_insert());
        (i, i)
    });
    let start_line = sel_start.line();
    let mut end_line = sel_end.line();
    if sel_end.line_offset() == 0 && end_line > start_line {
        end_line -= 1;
    }

    let lines: Vec<String> = (start_line..=end_line)
        .map(|l| {
            let Some(s) = buffer.iter_at_line(l) else {
                return String::new();
            };
            let mut e = s;
            e.forward_to_line_end();
            buffer.text(&s, &e, true).to_string()
        })
        .collect();

    let all_commented = lines
        .iter()
        .filter(|l| !l.trim().is_empty())
        .all(|l| l.trim_start().starts_with("--"));

    buffer.begin_user_action();
    for (offset, original) in lines.iter().enumerate() {
        if original.trim().is_empty() {
            continue;
        }
        let line_n = start_line + offset as i32;
        let leading_chars: i32 = original.chars().take_while(|c| c.is_whitespace()).count() as i32;
        let Some(mut iter) = buffer.iter_at_line(line_n) else {
            continue;
        };
        iter.forward_chars(leading_chars);

        if all_commented {
            let trimmed = original.trim_start();
            let strip_chars: i32 = if trimmed.starts_with("-- ") {
                3
            } else if trimmed.starts_with("--") {
                2
            } else {
                0
            };
            if strip_chars > 0 {
                let mut end = iter;
                end.forward_chars(strip_chars);
                buffer.delete(&mut iter, &mut end);
            }
        } else {
            buffer.insert(&mut iter, "-- ");
        }
    }
    buffer.end_user_action();
}

pub(super) const MAX_ANALYSIS_BYTES: usize = 200_000;

pub(super) fn analysis_text(buffer: &gtk::TextBuffer) -> Option<gtk::glib::GString> {
    if buffer.char_count() as usize > MAX_ANALYSIS_BYTES {
        return None;
    }
    let (start, end) = buffer.bounds();
    let text = buffer.text(&start, &end, true);
    (text.len() <= MAX_ANALYSIS_BYTES).then_some(text)
}

pub(super) fn read_sql_text(path: &std::path::Path, max_bytes: u64) -> Result<String, String> {
    tablepro_core::text_file::read_text_file(path, max_bytes)
        .map(|file| file.text)
        .map_err(|error| super::open_file::file_error_message(&error))
}

pub(super) fn export_name_for_query(query: &str) -> String {
    if query.trim().is_empty() {
        return crate::tr!("query-results");
    }
    let label = super::derive_tab_label(query);
    let mut slug = String::new();
    for character in label.chars() {
        if character.is_alphanumeric() {
            slug.push(character.to_ascii_lowercase());
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        crate::tr!("query-results")
    } else {
        slug.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn run_uses_the_selection_when_there_is_one_and_the_whole_buffer_otherwise() {
        gtk::init().unwrap();
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text("SELECT 1;\nSELECT 2;");
        assert_eq!(text_to_run(&buffer), "SELECT 1;\nSELECT 2;");
        buffer.select_range(&buffer.iter_at_line(1).unwrap(), &buffer.end_iter());
        assert_eq!(text_to_run(&buffer), "SELECT 2;");
        buffer.set_text("SELECT 1;\n   \nSELECT 2;");
        let blank = buffer.iter_at_line(1).unwrap();
        let mut blank_end = blank;
        blank_end.forward_to_line_end();
        buffer.select_range(&blank, &blank_end);
        assert_eq!(
            text_to_run(&buffer),
            "SELECT 1;\n   \nSELECT 2;",
            "a blank selection falls back to the whole script"
        );
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn advisory_text_is_bounded_by_utf8_bytes_without_truncating_the_buffer() {
        gtk::init().unwrap();
        let buffer = gtk::TextBuffer::new(None);
        let ascii = "a".repeat(MAX_ANALYSIS_BYTES);
        buffer.set_text(&ascii);
        assert_eq!(analysis_text(&buffer).as_deref(), Some(ascii.as_str()));
        buffer.insert(&mut buffer.end_iter(), "b");
        assert!(analysis_text(&buffer).is_none());
        assert_eq!(buffer.char_count() as usize, MAX_ANALYSIS_BYTES + 1);
        let unicode = "東京".repeat(MAX_ANALYSIS_BYTES / 6);
        buffer.set_text(&unicode);
        assert_eq!(analysis_text(&buffer).as_deref(), Some(unicode.as_str()));
        buffer.insert(&mut buffer.end_iter(), "東京");
        assert!(analysis_text(&buffer).is_none());
        assert_eq!(
            buffer.text(&buffer.start_iter(), &buffer.end_iter(), true),
            unicode + "東京"
        );
    }
}
