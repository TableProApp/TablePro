use relm4::gtk;
use relm4::gtk::prelude::*;

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
            buffer.text(&s, &e, false).to_string()
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
