//! Draws the diagram into a snapshot, in diagram units: the screen and
//! an export go through the same calls.

use std::collections::BTreeSet;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::{gdk, graphene, gsk};

use super::card_text::{CardText, PAD_X, size};
use super::model::SchemaDiagram;
use super::palette::Palette;
use super::scene::{Card, EdgePath, Rect};

const RADIUS: f32 = 8.0;
const LINE_WIDTH: f32 = 1.5;
const SELECTED_LINE_WIDTH: f32 = 2.5;
/// Below this zoom the rows' text is a few pixels tall, so only the
/// table names are drawn.
pub(crate) const DETAIL_ZOOM: f64 = 0.4;

/// What one frame shows.
pub(crate) struct Frame<'a> {
    pub diagram: &'a SchemaDiagram,
    pub texts: &'a [CardText],
    pub cards: &'a [Card],
    pub edges: &'a [EdgePath],
    pub order: &'a [usize],
    pub selected: Option<usize>,
    /// The card the keyboard is on, drawn with a focus ring.
    pub focused: Option<usize>,
    pub detail: bool,
}

pub(crate) fn draw(snapshot: &gtk::Snapshot, frame: &Frame<'_>, visible: &Rect, palette: &Palette) {
    let keyed = selected_rows(frame);
    let touches = |relation: usize| {
        frame.selected.is_some_and(|selected| {
            frame
                .diagram
                .relations
                .get(relation)
                .is_some_and(|found| found.from == selected || found.to == selected)
        })
    };
    // The selected table's lines go over the others.
    for pass in [false, true] {
        for (at, edge) in frame.edges.iter().enumerate() {
            if touches(at) != pass || !edge.bounds().intersects(visible) {
                continue;
            }
            let Some(relation) = frame.diagram.relations.get(at) else {
                continue;
            };
            let color = if pass { palette.accent } else { palette.line };
            let width = if pass { SELECTED_LINE_WIDTH } else { LINE_WIDTH };
            line(snapshot, edge, color, width);
            markers(snapshot, edge, relation.optional, relation.unique, color, palette.card);
        }
    }
    for &at in frame.order {
        let (Some(card), Some(text)) = (frame.cards.get(at), frame.texts.get(at)) else {
            continue;
        };
        if !card.rect().intersects(visible) {
            continue;
        }
        let rows = keyed.iter().filter(|(table, _)| *table == at).map(|(_, row)| *row);
        draw_card(
            snapshot,
            CardDraw {
                card,
                text,
                highlighted: rows.collect(),
                selected: frame.selected == Some(at),
                focused: frame.focused == Some(at),
                detail: frame.detail,
            },
            palette,
        );
    }
}

/// The (table, row) pairs of the selected table's keys, at both ends.
fn selected_rows(frame: &Frame<'_>) -> BTreeSet<(usize, usize)> {
    let Some(selected) = frame.selected else {
        return BTreeSet::new();
    };
    frame
        .diagram
        .relations
        .iter()
        .filter(|relation| relation.from == selected || relation.to == selected)
        .flat_map(|relation| {
            let from = relation.from_columns.iter().map(move |&row| (relation.from, row));
            let to = relation.to_columns.iter().map(move |&row| (relation.to, row));
            from.chain(to)
        })
        .collect()
}

fn point(x: f64, y: f64) -> graphene::Point {
    graphene::Point::new(x as f32, y as f32)
}

fn rect(rect: &Rect) -> graphene::Rect {
    graphene::Rect::new(rect.x as f32, rect.y as f32, rect.width as f32, rect.height as f32)
}

fn line(snapshot: &gtk::Snapshot, edge: &EdgePath, color: gdk::RGBA, width: f32) {
    let builder = gsk::PathBuilder::new();
    builder.move_to(edge.start.x as f32, edge.start.y as f32);
    builder.line_to(edge.start_stub.x as f32, edge.start_stub.y as f32);
    builder.cubic_to(
        edge.control_start.x as f32,
        edge.control_start.y as f32,
        edge.control_end.x as f32,
        edge.control_end.y as f32,
        edge.end_stub.x as f32,
        edge.end_stub.y as f32,
    );
    builder.line_to(edge.end.x as f32, edge.end.y as f32);
    let stroke = gsk::Stroke::new(width);
    stroke.set_line_cap(gsk::LineCap::Round);
    snapshot.append_stroke(&builder.to_path(), &stroke, &color);
}

/// Crow's foot notation. At the referenced table: one bar and a second
/// bar, or a circle when the key takes NULL (zero or one). At the table
/// that holds the key: a fork for many or a bar for at most one, and a
/// circle, since a referenced row need not be pointed at.
fn markers(snapshot: &gtk::Snapshot, edge: &EdgePath, optional: bool, unique: bool, color: gdk::RGBA, fill: gdk::RGBA) {
    let lines = gsk::PathBuilder::new();
    let circles = gsk::PathBuilder::new();
    let bar = |at: f64, x: f64, y: f64, dir: f64| {
        lines.move_to((x + dir * at) as f32, (y - 6.0) as f32);
        lines.line_to((x + dir * at) as f32, (y + 6.0) as f32);
    };
    let (ex, ey, edir) = (edge.end.x, edge.end.y, edge.end_dir);
    bar(6.0, ex, ey, edir);
    if optional {
        circles.add_circle(&point(ex + edir * 13.0, ey), 3.5);
    } else {
        bar(11.0, ex, ey, edir);
    }
    let (sx, sy, sdir) = (edge.start.x, edge.start.y, edge.start_dir);
    if unique {
        bar(6.0, sx, sy, sdir);
    } else {
        for spread in [-6.0, 0.0, 6.0] {
            lines.move_to((sx + sdir * 10.0) as f32, sy as f32);
            lines.line_to(sx as f32, (sy + spread) as f32);
        }
    }
    circles.add_circle(&point(sx + sdir * 14.0, sy), 3.5);
    let stroke = gsk::Stroke::new(LINE_WIDTH);
    stroke.set_line_cap(gsk::LineCap::Round);
    let circles = circles.to_path();
    snapshot.append_fill(&circles, gsk::FillRule::Winding, &fill);
    snapshot.append_stroke(&circles, &stroke, &color);
    snapshot.append_stroke(&lines.to_path(), &stroke, &color);
}

struct CardDraw<'a> {
    card: &'a Card,
    text: &'a CardText,
    highlighted: BTreeSet<usize>,
    selected: bool,
    focused: bool,
    detail: bool,
}

fn draw_card(snapshot: &gtk::Snapshot, draw: CardDraw<'_>, palette: &Palette) {
    let CardDraw {
        card,
        text,
        highlighted,
        selected,
        focused,
        detail,
    } = draw;
    let bounds = card.rect();
    let outline = gsk::RoundedRect::from_rect(rect(&bounds), RADIUS);
    let header = Rect {
        height: card.shape.header_height,
        ..bounds
    };
    snapshot.push_rounded_clip(&outline);
    snapshot.append_color(&palette.card, &rect(&bounds));
    let header_color = if selected { palette.highlight } else { palette.header };
    snapshot.append_color(&header_color, &rect(&header));
    for &row in &highlighted {
        if row < card.shape.rows {
            snapshot.append_color(&palette.highlight, &rect(&card.row_rect(row)));
        }
    }
    snapshot.append_color(
        &palette.border,
        &rect(&Rect {
            y: header.bottom() - 1.0,
            height: 1.0,
            ..header
        }),
    );
    snapshot.pop();
    let (border, width) = if selected {
        (palette.accent, 2.0)
    } else {
        (palette.border, 1.0)
    };
    snapshot.append_border(&outline, &[width; 4], &[border; 4]);
    if focused {
        let ring = Rect {
            x: bounds.x - 4.0,
            y: bounds.y - 4.0,
            width: bounds.width + 8.0,
            height: bounds.height + 8.0,
        };
        let mut ring_color = palette.accent;
        ring_color.set_alpha(0.5);
        snapshot.append_border(
            &gsk::RoundedRect::from_rect(rect(&ring), RADIUS + 4.0),
            &[2.0; 4],
            &[ring_color; 4],
        );
    }
    let (_, header_height) = size(&text.header);
    layout_at(
        snapshot,
        &text.header,
        bounds.x + PAD_X,
        bounds.y + (card.shape.header_height - header_height) / 2.0,
        palette.text,
    );
    if detail {
        draw_rows(snapshot, card, text, palette);
    }
}

fn draw_rows(snapshot: &gtk::Snapshot, card: &Card, text: &CardText, palette: &Palette) {
    for (at, row) in text.rows.iter().enumerate() {
        let bounds = card.row_rect(at);
        let middle = |layout: &gtk4::pango::Layout| bounds.y + (bounds.height - size(layout).1) / 2.0;
        if let Some(badge) = &row.badge {
            layout_at(snapshot, badge, bounds.x + PAD_X, middle(badge), palette.dim_text);
        }
        layout_at(
            snapshot,
            &row.name,
            bounds.x + text.name_x,
            middle(&row.name),
            palette.text,
        );
        let (type_width, _) = size(&row.type_name);
        layout_at(
            snapshot,
            &row.type_name,
            bounds.right() - PAD_X - type_width,
            middle(&row.type_name),
            palette.dim_text,
        );
    }
}

fn layout_at(snapshot: &gtk::Snapshot, layout: &gtk4::pango::Layout, x: f64, y: f64, color: gdk::RGBA) {
    snapshot.save();
    snapshot.translate(&point(x, y));
    snapshot.append_layout(layout, &color);
    snapshot.restore();
}
