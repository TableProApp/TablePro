use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib, graphene};
use libadwaita as adw;
use sourceview5::prelude::*;

use super::EditorView;

/// The carets besides GTK's own, as GTK draws its own: selections under
/// the text, carets over it and only while the view has the focus. The
/// editor never wraps lines, so a buffer line is a line on screen.
pub(super) fn carets(view: &EditorView, layer: gtk::TextViewLayer, snapshot: &gtk::Snapshot) {
    let carets = view.imp().carets.borrow();
    if carets.is_empty() {
        return;
    }
    let buffer = view.buffer();
    let visible = view.visible_rect();
    let (top, _) = view.line_at_y(visible.y());
    let (mut bottom, _) = view.line_at_y(visible.y() + visible.height());
    if !bottom.ends_line() {
        bottom.forward_to_line_end();
    }
    match layer {
        gtk::TextViewLayer::BelowText => {
            let color = selection_color(view);
            let right_edge = visible.x() + visible.width();
            for caret in carets.iter() {
                let (start, end) = caret.range(&buffer);
                if start == end || end < top || bottom < start {
                    continue;
                }
                let (start, end) = (start.max(top), end.min(bottom));
                for rect in selection_rects(view, &start, &end, right_edge) {
                    snapshot.append_color(&color, &rect);
                }
            }
        }
        gtk::TextViewLayer::AboveText if view.has_focus() => {
            let color = caret_color(view);
            let aspect = view.settings().gtk_cursor_aspect_ratio();
            for caret in carets.iter() {
                let insert = caret.insert(&buffer);
                if insert < top || bottom < insert {
                    continue;
                }
                let (strong, _) = view.cursor_locations(Some(&insert));
                let height = strong.height() as f32;
                // GTK's own: gtk/gtkrender.c, draw_insertion_cursor.
                let width = (f64::from(strong.height()) * aspect + 1.0).floor() as f32;
                snapshot.append_color(
                    &color,
                    &graphene::Rect::new(strong.x() as f32, strong.y() as f32, width.max(1.0), height),
                );
            }
        }
        _ => {}
    }
}

/// Each selected character's own box, so text that runs right to left is
/// covered where it shows; a selected line end fills to the edge, as GTK
/// fills its own.
pub(super) fn selection_rects(
    view: &EditorView,
    start: &gtk::TextIter,
    end: &gtk::TextIter,
    right_edge: i32,
) -> Vec<graphene::Rect> {
    let mut boxes: Vec<(i32, i32, i32, i32)> = Vec::new();
    let mut at = *start;
    while at < *end {
        let place = view.iter_location(&at);
        let (y, height) = view.line_yrange(&at);
        // Pango gives a character that runs right to left a negative width.
        let (left, width) = if at.ends_line() {
            (place.x(), right_edge - place.x())
        } else if place.width() < 0 {
            (place.x() + place.width(), -place.width())
        } else {
            (place.x(), place.width())
        };
        // GTK rounds each box's edge and width apart, so neighbours can be
        // a pixel apart or over each other.
        match boxes.last_mut() {
            Some((x, row, w, _)) if *row == y && left <= *x + *w + 1 && *x <= left + width + 1 => {
                let right = (*x + *w).max(left + width);
                *x = (*x).min(left);
                *w = right - *x;
            }
            _ => boxes.push((left, y, width, height)),
        }
        if !at.forward_char() {
            break;
        }
    }
    boxes
        .into_iter()
        .filter(|(_, _, width, _)| *width > 0)
        .map(|(x, y, width, height)| graphene::Rect::new(x as f32, y as f32, width as f32, height as f32))
        .collect()
}

fn scheme_style(view: &EditorView, id: &str) -> Option<sourceview5::Style> {
    view.buffer()
        .downcast::<sourceview5::Buffer>()
        .ok()?
        .style_scheme()?
        .style(id)
}

fn parsed(color: Option<glib::GString>) -> Option<gdk::RGBA> {
    gdk::RGBA::parse(color?.as_str()).ok()
}

/// The scheme's cursor colour, which GtkSourceView makes the caret
/// colour, or the text colour, which libadwaita's caret is.
fn caret_color(view: &EditorView) -> gdk::RGBA {
    scheme_style(view, "cursor")
        .filter(sourceview5::Style::is_foreground_set)
        .and_then(|style| parsed(style.foreground()))
        .unwrap_or_else(|| view.color())
}

/// The scheme's selection, read as GtkSourceView turns it into CSS
/// (gtksourcestylescheme.c, generate_css_style), or libadwaita's.
pub(super) fn selection_color(view: &EditorView) -> gdk::RGBA {
    let focused = view.has_focus();
    let style = if focused {
        scheme_style(view, "selection")
    } else {
        scheme_style(view, "selection-unfocused").or_else(|| scheme_style(view, "selection"))
    };
    if let Some(style) = style.filter(sourceview5::Style::is_background_set)
        && let Some(background) = parsed(style.background())
    {
        // The text under another caret's selection keeps its own colour,
        // so a solid selection would hide it, as GtkSourceView's
        // fix_broken_selection says of a selection with no text colour.
        if background.alpha() >= 1.0 {
            return background.with_alpha(0.3);
        }
        return background;
    }
    // libadwaita 1.9, _common.scss: selection, and selection:focus-within.
    if focused {
        let accent = adw::StyleManager::default().accent_color_rgba();
        accent.with_alpha(accent.alpha() * 0.3)
    } else {
        let text = view.color();
        text.with_alpha(text.alpha() * 0.1)
    }
}
