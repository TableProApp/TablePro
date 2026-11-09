use std::ops::Range;

use gtk4::prelude::*;
use gtk4::{self as gtk, gdk, pango};

use crate::services::grid::special_characters::{Mark, reveal, special_characters};

// Adwaita's orange 3 under a third of its strength, as the macOS app boxes
// each mark in the system orange: the value's own colour stays readable on
// it in both styles and on a selected row.
const TINT: (u16, u16, u16) = (0xFFFF, 0x7878, 0x0000);
const TINT_ALPHA: u16 = 0x5555;
const TAG_NAME: &str = "tp-special-character";

fn tint_rgba() -> gdk::RGBA {
    gdk::RGBA::new(1.0, 120.0 / 255.0, 0.0, f32::from(TINT_ALPHA) / f32::from(u16::MAX))
}

// An editor cannot write a character's name in its place, so Pango draws
// each one the way it shows hidden characters. Not SPACES: a text view then
// marks every space of the paragraph, and a special space has the tint.
fn shown_in_editors() -> pango::ShowFlags {
    pango::ShowFlags::LINE_BREAKS | pango::ShowFlags::IGNORABLES
}

fn byte_index(index: usize) -> u32 {
    u32::try_from(index).unwrap_or(u32::MAX)
}

fn insert(attributes: &pango::AttrList, attribute: impl Into<pango::Attribute>, range: &Range<u32>) {
    let mut attribute = attribute.into();
    attribute.set_start_index(range.start);
    attribute.set_end_index(range.end);
    attributes.insert(attribute);
}

fn insert_tint(attributes: &pango::AttrList, range: &Range<u32>) {
    let (red, green, blue) = TINT;
    insert(attributes, pango::AttrColor::new_background(red, green, blue), range);
    insert(attributes, pango::AttrInt::new_background_alpha(TINT_ALPHA), range);
}

/// `base` with a tinted box under each mark, a label a size smaller so it
/// reads apart from the value around it.
pub(crate) fn marked_attributes(base: Option<&pango::AttrList>, marks: &[Mark]) -> pango::AttrList {
    let attributes = base.and_then(pango::AttrList::copy).unwrap_or_default();
    for mark in marks {
        let range = byte_index(mark.range.start)..byte_index(mark.range.end);
        insert_tint(&attributes, &range);
        if mark.labelled {
            insert(&attributes, pango::AttrFloat::new_scale(pango::SCALE_SMALL), &range);
        }
    }
    attributes
}

/// A one-line view of a value, with its special characters written as
/// their marks while `marks` holds.
pub(crate) fn show_value(display: &gtk::Inscription, text: &str, attributes: Option<&pango::AttrList>, marks: bool) {
    match marks.then(|| reveal(text)).flatten() {
        Some(revealed) => {
            display.set_text(Some(&revealed.text));
            display.set_attributes(Some(&marked_attributes(attributes, &revealed.marks)));
        }
        None => {
            display.set_text(Some(text));
            display.set_attributes(attributes);
        }
    }
}

/// The inline editor's marks, rebuilt from its text; its text stays as typed.
pub(crate) fn mark_field(field: &gtk::Text, marks: bool) {
    let attributes = pango::AttrList::new();
    let text = field.text();
    let mut found = false;
    if marks {
        for special in special_characters(&text, false) {
            let range = byte_index(special.range.start)..byte_index(special.range.end);
            insert(&attributes, pango::AttrInt::new_show(shown_in_editors()), &range);
            insert_tint(&attributes, &range);
            found = true;
        }
    }
    field.set_attributes(found.then_some(&attributes));
}

/// A text view's marks, through a tag, so neither its text, its selection
/// nor its undo history changes.
pub(crate) fn mark_buffer(buffer: &gtk::TextBuffer, marks: bool) {
    let (start, end) = buffer.bounds();
    let tag = special_tag(buffer);
    buffer.remove_tag(&tag, &start, &end);
    if !marks {
        return;
    }
    let text = buffer.text(&start, &end, true);
    let mut offset = 0;
    let mut scanned = 0;
    for special in special_characters(&text, false) {
        offset += char_count(&text[scanned..special.range.start]);
        let length = char_count(&text[special.range.clone()]);
        buffer.apply_tag(
            &tag,
            &buffer.iter_at_offset(offset),
            &buffer.iter_at_offset(offset + length),
        );
        offset += length;
        scanned = special.range.end;
    }
}

fn char_count(text: &str) -> i32 {
    i32::try_from(text.chars().count()).unwrap_or(i32::MAX)
}

fn special_tag(buffer: &gtk::TextBuffer) -> gtk::TextTag {
    let table = buffer.tag_table();
    if let Some(tag) = table.lookup(TAG_NAME) {
        return tag;
    }
    let tag = gtk::TextTag::builder()
        .name(TAG_NAME)
        .show_spaces(shown_in_editors())
        .background_rgba(&tint_rgba())
        .build();
    table.add(&tag);
    tag
}

#[cfg(test)]
pub(crate) fn tagged_ranges(buffer: &gtk::TextBuffer) -> Vec<(i32, i32)> {
    let Some(tag) = buffer.tag_table().lookup(TAG_NAME) else {
        return Vec::new();
    };
    let mut ranges = Vec::new();
    let mut at = buffer.start_iter();
    loop {
        if at.starts_tag(Some(&tag)) {
            let mut end = at;
            end.forward_to_tag_toggle(Some(&tag));
            ranges.push((at.offset(), end.offset()));
        }
        if !at.forward_to_tag_toggle(Some(&tag)) {
            return ranges;
        }
    }
}
