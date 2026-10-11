use std::cell::Cell;
use std::rc::Rc;
use std::sync::Arc;

use relm4::gtk::{self, glib, prelude::*};
use uuid::Uuid;

use super::statement_cursor::{cursor_byte_offset, statement_range_at};
use crate::services::database_service::DatabaseService;

const MAX_BANDED_BYTES: usize = 200_000;
const TAG_NAME: &str = "tp-current-statement";

fn band_char_range(text: &str, driver: &str, cursor_chars: usize) -> Option<(i32, i32)> {
    if text.len() > MAX_BANDED_BYTES {
        return None;
    }
    let range = statement_range_at(text, driver, cursor_byte_offset(text, cursor_chars))?;
    Some((
        text[..range.start].chars().count() as i32,
        text[..range.end].chars().count() as i32,
    ))
}

fn refresh(buffer: &gtk::TextBuffer, driver: &str) {
    let (start, end) = buffer.bounds();
    buffer.remove_tag_by_name(TAG_NAME, &start, &end);
    let text = buffer.text(&start, &end, false).to_string();
    let cursor = buffer.iter_at_mark(&buffer.get_insert()).offset() as usize;
    let Some((from, to)) = band_char_range(&text, driver, cursor) else {
        return;
    };
    buffer.apply_tag_by_name(TAG_NAME, &buffer.iter_at_offset(from), &buffer.iter_at_offset(to));
}

pub fn install(buffer: &gtk::TextBuffer, database: Arc<DatabaseService>, connection_id: Option<Uuid>) {
    let tag = gtk::TextTag::builder()
        .name(TAG_NAME)
        .background_rgba(&gtk::gdk::RGBA::new(0.5, 0.5, 0.5, 0.12))
        .build();
    buffer.tag_table().add(&tag);
    let generation = Rc::new(Cell::new(0u32));
    let schedule = {
        let buffer = buffer.downgrade();
        move || {
            let ticket = generation.get().wrapping_add(1);
            generation.set(ticket);
            let buffer = buffer.clone();
            let database = database.clone();
            let generation = generation.clone();
            glib::idle_add_local_once(move || {
                let Some(buffer) = buffer.upgrade() else {
                    return;
                };
                if generation.get() != ticket {
                    return;
                }
                let driver = connection_id
                    .and_then(|id| database.metadata(id))
                    .map(|metadata| metadata.driver_id)
                    .unwrap_or_default();
                refresh(&buffer, &driver);
            });
        }
    };
    let on_change = schedule.clone();
    buffer.connect_changed(move |_| on_change());
    buffer.connect_mark_set(move |buffer, _, mark| {
        if mark == &buffer.get_insert() {
            schedule();
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_band_range_is_counted_in_characters_for_the_text_buffer() {
        let sql = "SELECT '東京';\nSELECT 2";
        let cursor = sql.chars().count() - 2;
        let (from, to) = band_char_range(sql, "postgres", cursor).unwrap();
        let chars: Vec<char> = sql.chars().collect();
        assert_eq!(chars[from as usize..to as usize].iter().collect::<String>(), "SELECT 2");
    }

    #[test]
    fn a_huge_script_gets_no_band() {
        let sql = "SELECT 1;\n".repeat(MAX_BANDED_BYTES);
        assert_eq!(band_char_range(&sql, "postgres", 3), None);
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn moving_the_cursor_moves_the_band_between_statements() {
        gtk::init().unwrap();
        let buffer = gtk::TextBuffer::new(None);
        buffer.set_text("SELECT 1;\nSELECT 2");
        let tag = gtk::TextTag::builder().name(TAG_NAME).build();
        buffer.tag_table().add(&tag);
        buffer.place_cursor(&buffer.iter_at_offset(2));
        refresh(&buffer, "postgres");
        assert!(buffer.iter_at_offset(3).has_tag(&tag));
        assert!(!buffer.iter_at_offset(12).has_tag(&tag));
        buffer.place_cursor(&buffer.iter_at_offset(14));
        refresh(&buffer, "postgres");
        assert!(buffer.iter_at_offset(12).has_tag(&tag));
        assert!(!buffer.iter_at_offset(3).has_tag(&tag));
    }
}
