use gtk4::pango;

use super::model::{DiagramColumn, DiagramTable};
use super::scene::CardShape;

pub(crate) const PAD_X: f64 = 12.0;
const BADGE_GAP: f64 = 6.0;
const TYPE_GAP: f64 = 16.0;
const HEADER_PAD_Y: f64 = 8.0;
const ROW_PAD_Y: f64 = 3.0;
const FOOTER: f64 = 4.0;
const MIN_WIDTH: f64 = 160.0;
/// Longer names and types end in an ellipsis; the screen reader's
/// description and the tooltip-free export keep the whole name.
const MAX_HEADER: i32 = 420;
const MAX_NAME: i32 = 240;
const MAX_TYPE: i32 = 180;

/// A card's text, laid out once, and the shape it gives the card.
pub(crate) struct CardText {
    pub header: pango::Layout,
    pub rows: Vec<RowText>,
    pub shape: CardShape,
    /// Where each row's name starts, from the card's left edge.
    pub name_x: f64,
}

pub(crate) struct RowText {
    pub badge: Option<pango::Layout>,
    pub name: pango::Layout,
    pub type_name: pango::Layout,
}

impl CardText {
    pub(crate) fn lay_out(context: &pango::Context, table: &DiagramTable) -> Self {
        let header = text(context, &table.table.name, MAX_HEADER, Style::Bold);
        let rows: Vec<RowText> = table.columns.iter().map(|column| row(context, column)).collect();
        let (header_width, header_height) = size(&header);
        let line = rows
            .iter()
            .map(|row| size(&row.name).1.max(size(&row.type_name).1))
            .fold(header_height, f64::max);
        let badge_width = rows
            .iter()
            .filter_map(|row| row.badge.as_ref())
            .map(|badge| size(badge).0)
            .fold(0.0, f64::max);
        let name_width = rows.iter().map(|row| size(&row.name).0).fold(0.0, f64::max);
        let type_width = rows.iter().map(|row| size(&row.type_name).0).fold(0.0, f64::max);
        let name_x = match badge_width > 0.0 {
            true => PAD_X + badge_width + BADGE_GAP,
            false => PAD_X,
        };
        let width = (name_x + name_width + TYPE_GAP + type_width + PAD_X)
            .max(header_width + 2.0 * PAD_X)
            .max(MIN_WIDTH)
            .ceil();
        let shape = CardShape {
            width,
            header_height: (header_height + 2.0 * HEADER_PAD_Y).ceil(),
            row_height: (line + 2.0 * ROW_PAD_Y).ceil(),
            rows: rows.len(),
            footer: FOOTER,
        };
        Self {
            header,
            rows,
            shape,
            name_x,
        }
    }
}

fn row(context: &pango::Context, column: &DiagramColumn) -> RowText {
    let mut badges = Vec::new();
    if column.primary_key {
        badges.push(crate::i18n::pgettext("diagram key badge", "PK"));
    }
    if column.foreign_key {
        badges.push(crate::i18n::pgettext("diagram key badge", "FK"));
    }
    let badge = (!badges.is_empty()).then(|| text(context, &badges.join(" "), MAX_NAME, Style::Badge));
    RowText {
        badge,
        name: text(context, &column.name, MAX_NAME, Style::Plain),
        type_name: text(context, &column.type_name, MAX_TYPE, Style::Plain),
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Style {
    Plain,
    Bold,
    /// A key badge: small bold capitals beside the name.
    Badge,
}

fn text(context: &pango::Context, value: &str, max: i32, style: Style) -> pango::Layout {
    let layout = pango::Layout::new(context);
    layout.set_text(value);
    layout.set_single_paragraph_mode(true);
    layout.set_ellipsize(pango::EllipsizeMode::End);
    layout.set_width(max * pango::SCALE);
    if style != Style::Plain {
        let list = pango::AttrList::new();
        list.insert(pango::AttrInt::new_weight(pango::Weight::Bold));
        if style == Style::Badge {
            list.insert(pango::AttrFloat::new_scale(0.75));
        }
        layout.set_attributes(Some(&list));
    }
    layout
}

/// Width and height in logical pixels.
pub(crate) fn size(layout: &pango::Layout) -> (f64, f64) {
    let (width, height) = layout.pixel_size();
    (f64::from(width), f64::from(height))
}

#[cfg(test)]
mod tests {
    use gtk4::prelude::*;
    use tablepro_core::meta::TableRef;

    use super::*;

    fn table(columns: &[(&str, &str, bool, bool)]) -> DiagramTable {
        DiagramTable {
            table: TableRef::unqualified("orders"),
            columns: columns
                .iter()
                .map(|&(name, type_name, primary_key, foreign_key)| DiagramColumn {
                    name: name.to_owned(),
                    type_name: type_name.to_owned(),
                    primary_key,
                    foreign_key,
                    nullable: false,
                })
                .collect(),
        }
    }

    #[gtk4::test]
    fn a_card_is_as_tall_as_its_rows_and_as_wide_as_its_longest_line() {
        let context = gtk4::Label::new(None).pango_context();
        let short = CardText::lay_out(&context, &table(&[("id", "integer", true, false)]));
        let long = CardText::lay_out(
            &context,
            &table(&[
                ("id", "integer", true, false),
                ("customer_reference_number", "character varying(255)", false, true),
            ]),
        );

        assert_eq!(long.shape.rows, 2);
        assert!(long.shape.size().height > short.shape.size().height);
        assert!(long.shape.width > short.shape.width);
        assert!(short.shape.width >= MIN_WIDTH);
        assert!(long.rows[1].badge.is_some() && long.rows[0].badge.is_some());
        assert!(long.name_x > PAD_X, "names start after the badges");
    }

    #[gtk4::test]
    fn a_very_long_name_is_cut_short() {
        let context = gtk4::Label::new(None).pango_context();
        let name = "n".repeat(500);
        let card = CardText::lay_out(&context, &table(&[(name.as_str(), "text", false, false)]));

        assert!(size(&card.rows[0].name).0 <= f64::from(MAX_NAME));
        assert!(card.rows[0].name.is_ellipsized());
    }
}
