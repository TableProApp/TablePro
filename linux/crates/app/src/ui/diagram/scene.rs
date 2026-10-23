//! Where each table's card and each key's line are, in diagram units.
//! At 100% one unit is one logical pixel.

use super::layout::{Point, Size};

/// The straight part of a line at each card, where its markers go.
pub(crate) const STUB: f64 = 18.0;
/// How far a line's curve leaves a card before it turns.
const BEND: f64 = 48.0;
/// The empty margin around the diagram, on screen and in an export.
pub(crate) const MARGIN: f64 = 40.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub(crate) fn right(&self) -> f64 {
        self.x + self.width
    }

    pub(crate) fn bottom(&self) -> f64 {
        self.y + self.height
    }

    pub(crate) fn contains(&self, point: Point) -> bool {
        point.x >= self.x && point.x < self.right() && point.y >= self.y && point.y < self.bottom()
    }

    pub(crate) fn intersects(&self, other: &Rect) -> bool {
        self.x < other.right() && other.x < self.right() && self.y < other.bottom() && other.y < self.bottom()
    }

    fn around(points: &[Point]) -> Rect {
        let (mut left, mut top) = (f64::INFINITY, f64::INFINITY);
        let (mut right, mut bottom) = (f64::NEG_INFINITY, f64::NEG_INFINITY);
        for point in points {
            left = left.min(point.x);
            top = top.min(point.y);
            right = right.max(point.x);
            bottom = bottom.max(point.y);
        }
        Rect {
            x: left,
            y: top,
            width: (right - left).max(0.0),
            height: (bottom - top).max(0.0),
        }
    }
}

/// A card's shape: its header and the height of each column's row.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct CardShape {
    pub width: f64,
    pub header_height: f64,
    pub row_height: f64,
    pub rows: usize,
    /// Below the last row, so it does not touch the card's edge.
    pub footer: f64,
}

impl CardShape {
    pub(crate) fn size(&self) -> Size {
        Size {
            width: self.width,
            height: self.header_height + self.row_height * self.rows as f64 + self.footer,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct Card {
    pub at: Point,
    pub shape: CardShape,
}

impl Card {
    pub(crate) fn rect(&self) -> Rect {
        let size = self.shape.size();
        Rect {
            x: self.at.x,
            y: self.at.y,
            width: size.width,
            height: size.height,
        }
    }

    pub(crate) fn row_rect(&self, row: usize) -> Rect {
        Rect {
            x: self.at.x,
            y: self.at.y + self.shape.header_height + self.shape.row_height * row as f64,
            width: self.shape.width,
            height: self.shape.row_height,
        }
    }

    /// Where a line meets the card: the middle of the first of `rows`,
    /// or of the header when the key names no column the card shows.
    fn anchor_y(&self, rows: &[usize]) -> f64 {
        match rows.first() {
            Some(&row) if row < self.shape.rows => {
                let rect = self.row_rect(row);
                rect.y + rect.height / 2.0
            }
            _ => self.at.y + self.shape.header_height / 2.0,
        }
    }
}

/// A key's line: straight out of each card for its markers, and a curve
/// between. `start` is at the card that holds the key.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct EdgePath {
    pub start: Point,
    pub start_stub: Point,
    pub control_start: Point,
    pub control_end: Point,
    pub end_stub: Point,
    pub end: Point,
    /// +1 when the line leaves `start` to the right, -1 to the left.
    pub start_dir: f64,
    pub end_dir: f64,
}

impl EdgePath {
    pub(crate) fn bounds(&self) -> Rect {
        Rect::around(&[
            self.start,
            self.start_stub,
            self.control_start,
            self.control_end,
            self.end_stub,
            self.end,
        ])
    }
}

/// The line from the holder's `from_rows` to the referenced card's
/// `to_rows`. Cards side by side join their facing edges; cards above
/// one another, and a card that points at itself, join on the right.
pub(crate) fn route(from: &Card, from_rows: &[usize], to: &Card, to_rows: &[usize]) -> EdgePath {
    let (a, b) = (from.rect(), to.rect());
    let (start_y, end_y) = (from.anchor_y(from_rows), to.anchor_y(to_rows));
    let (start_dir, end_dir) = if b.right() + 2.0 * STUB <= a.x {
        (-1.0, 1.0)
    } else if a.right() + 2.0 * STUB <= b.x {
        (1.0, -1.0)
    } else {
        (1.0, 1.0)
    };
    let start = Point {
        x: if start_dir > 0.0 { a.right() } else { a.x },
        y: start_y,
    };
    let end = Point {
        x: if end_dir > 0.0 { b.right() } else { b.x },
        y: end_y,
    };
    let start_stub = Point {
        x: start.x + start_dir * STUB,
        y: start.y,
    };
    let end_stub = Point {
        x: end.x + end_dir * STUB,
        y: end.y,
    };
    let (control_start, control_end) = if start_dir == end_dir {
        // Out past the wider of the two cards, then back.
        let outer = start_stub.x.max(end_stub.x) + BEND;
        // A key on the row it points at would close on itself.
        let lift = match (start.y - end.y).abs() < from.shape.row_height / 2.0 {
            true => from.shape.row_height,
            false => 0.0,
        };
        (
            Point {
                x: outer,
                y: start_stub.y - lift,
            },
            Point {
                x: outer,
                y: end_stub.y + lift,
            },
        )
    } else {
        let reach = BEND.max((end_stub.x - start_stub.x).abs() / 2.0);
        (
            Point {
                x: start_stub.x + start_dir * reach,
                y: start_stub.y,
            },
            Point {
                x: end_stub.x + end_dir * reach,
                y: end_stub.y,
            },
        )
    };
    EdgePath {
        start,
        start_stub,
        control_start,
        control_end,
        end_stub,
        end,
        start_dir,
        end_dir,
    }
}

/// Everything the diagram covers, with `MARGIN` round it, or `None`
/// with nothing in it.
pub(crate) fn extent(cards: &[Card], edges: &[EdgePath]) -> Option<Rect> {
    let mut corners: Vec<Point> = Vec::with_capacity((cards.len() + edges.len()) * 2);
    for rect in cards.iter().map(Card::rect).chain(edges.iter().map(EdgePath::bounds)) {
        corners.push(Point { x: rect.x, y: rect.y });
        corners.push(Point {
            x: rect.right(),
            y: rect.bottom(),
        });
    }
    if corners.is_empty() {
        return None;
    }
    let inner = Rect::around(&corners);
    Some(Rect {
        x: inner.x - MARGIN,
        y: inner.y - MARGIN,
        width: inner.width + 2.0 * MARGIN,
        height: inner.height + 2.0 * MARGIN,
    })
}

/// The card under `point`, the one drawn last when cards overlap.
/// `order` is the drawing order.
pub(crate) fn hit(cards: &[Card], order: &[usize], point: Point) -> Option<usize> {
    order
        .iter()
        .rev()
        .copied()
        .find(|&at| cards.get(at).is_some_and(|card| card.rect().contains(point)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(x: f64, y: f64) -> Card {
        Card {
            at: Point { x, y },
            shape: CardShape {
                width: 200.0,
                header_height: 32.0,
                row_height: 24.0,
                rows: 4,
                footer: 4.0,
            },
        }
    }

    #[test]
    fn a_line_joins_the_facing_edges_at_the_key_rows() {
        let orders = card(400.0, 0.0);
        let customers = card(0.0, 100.0);

        let path = route(&orders, &[2], &customers, &[0]);

        assert_eq!(
            path.start,
            Point {
                x: 400.0,
                y: 32.0 + 48.0 + 12.0
            }
        );
        assert_eq!(
            path.end,
            Point {
                x: 200.0,
                y: 100.0 + 32.0 + 12.0
            }
        );
        assert_eq!((path.start_dir, path.end_dir), (-1.0, 1.0));
        assert_eq!(path.start_stub.x, 400.0 - STUB);
        assert_eq!(path.end_stub.x, 200.0 + STUB);
    }

    #[test]
    fn stacked_cards_and_a_self_reference_join_on_the_right() {
        let upper = card(0.0, 0.0);
        let lower = card(20.0, 300.0);

        let stacked = route(&lower, &[1], &upper, &[0]);
        let own = route(&upper, &[0], &upper, &[0]);

        assert_eq!((stacked.start_dir, stacked.end_dir), (1.0, 1.0));
        assert!(stacked.control_start.x > lower.rect().right());
        assert_eq!((own.start_dir, own.end_dir), (1.0, 1.0));
        assert_ne!(own.control_start.y, own.control_end.y, "a loop on one row would vanish");
    }

    #[test]
    fn a_key_with_no_shown_column_meets_the_header() {
        let orders = card(400.0, 0.0);
        let customers = card(0.0, 0.0);

        let path = route(&orders, &[], &customers, &[9]);

        assert_eq!(path.start.y, 16.0);
        assert_eq!(path.end.y, 16.0);
    }

    #[test]
    fn the_extent_holds_cards_and_lines_with_a_margin() {
        let cards = [card(0.0, 0.0), card(0.0, 300.0)];
        let edges = [route(&cards[1], &[0], &cards[0], &[0])];

        let extent = extent(&cards, &edges).expect("an extent");

        assert_eq!((extent.x, extent.y), (-MARGIN, -MARGIN));
        assert!(extent.right() >= edges[0].control_start.x + MARGIN);
        assert_eq!(extent.bottom(), 300.0 + cards[1].rect().height + MARGIN);
        assert_eq!(super::extent(&[], &[]), None);
    }

    #[test]
    fn a_hit_finds_the_card_drawn_last() {
        let cards = [card(0.0, 0.0), card(100.0, 50.0)];

        assert_eq!(hit(&cards, &[0, 1], Point { x: 150.0, y: 60.0 }), Some(1));
        assert_eq!(hit(&cards, &[1, 0], Point { x: 150.0, y: 60.0 }), Some(0));
        assert_eq!(hit(&cards, &[0, 1], Point { x: 50.0, y: 10.0 }), Some(0));
        assert_eq!(hit(&cards, &[0, 1], Point { x: 900.0, y: 10.0 }), None);
    }
}
