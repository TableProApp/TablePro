use std::collections::HashMap;

use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib, graphene, gsk};
use tablepro_core::meta::TableRef;

use super::canvas_imp as imp;
use super::card_text::CardText;
use super::describe::table_description;
use super::draw::{self, Frame};
use super::layout::{self, COLUMN_GAP, Point, ROW_GAP};
use super::model::SchemaDiagram;
use super::node::DiagramNode;
use super::scene::{self, Card, EdgePath, Rect};
use super::zoom;

glib::wrapper! {
    /// The diagram: cards and lines drawn in one widget that scrolls in
    /// a scrolled window, zooms, and moves its cards. Each card also has
    /// a `DiagramNode` where it is drawn, which the keyboard and a screen
    /// reader reach.
    pub struct DiagramCanvas(ObjectSubclass<imp::DiagramCanvas>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget, gtk::Scrollable;
}

pub(crate) struct Content {
    pub diagram: SchemaDiagram,
    pub texts: Vec<CardText>,
    pub cards: Vec<Card>,
    /// One per relation, in the diagram's order.
    pub edges: Vec<EdgePath>,
    /// The order cards are drawn in; a card moved last is on top.
    pub order: Vec<usize>,
    pub nodes: Vec<DiagramNode>,
    pub extent: Rect,
    /// The user moved a card since the automatic layout placed them.
    pub moved: bool,
}

impl Content {
    fn route_all(&mut self) {
        self.edges = self
            .diagram
            .relations
            .iter()
            .map(|relation| {
                let (from, to) = (self.cards[relation.from], self.cards[relation.to]);
                scene::route(&from, &relation.from_columns, &to, &relation.to_columns)
            })
            .collect();
    }

    fn reroute(&mut self, table: usize) {
        for (at, relation) in self.diagram.relations.iter().enumerate() {
            if relation.from != table && relation.to != table {
                continue;
            }
            let (Some(from), Some(to)) = (self.cards.get(relation.from), self.cards.get(relation.to)) else {
                continue;
            };
            if let Some(edge) = self.edges.get_mut(at) {
                *edge = scene::route(from, &relation.from_columns, to, &relation.to_columns);
            }
        }
    }

    fn measure_extent(&mut self) {
        self.extent = self.bounds();
    }

    /// What the cards and lines cover now, which Best Fit and an export
    /// show. The scrolled area can be larger: it keeps the room a moved
    /// card left.
    fn bounds(&self) -> Rect {
        scene::extent(&self.cards, &self.edges).unwrap_or(Rect {
            x: 0.0,
            y: 0.0,
            width: 1.0,
            height: 1.0,
        })
    }

    fn arrange(&mut self) {
        let sizes: Vec<layout::Size> = self.texts.iter().map(|text| text.shape.size()).collect();
        let pairs: Vec<(usize, usize)> = self
            .diagram
            .relations
            .iter()
            .map(|relation| (relation.from, relation.to))
            .collect();
        let positions = layout::arrange(&sizes, &pairs);
        for (card, at) in self.cards.iter_mut().zip(positions) {
            card.at = at;
        }
        self.moved = false;
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum Drag {
    Card { index: usize, from: Point, moved: bool },
    Pan { scroll: (f64, f64) },
}

/// A colour of the theme, read from a hidden widget whose `color` the
/// stylesheet sets to one of libadwaita's colour variables.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Probe {
    WindowBackground,
    CardBackground,
    CardForeground,
    Border,
    Accent,
}

impl Probe {
    pub(crate) const ALL: [Self; 5] = [
        Self::WindowBackground,
        Self::CardBackground,
        Self::CardForeground,
        Self::Border,
        Self::Accent,
    ];

    pub(crate) fn css_class(self) -> &'static str {
        match self {
            Self::WindowBackground => "tp-diagram-window-bg",
            Self::CardBackground => "tp-diagram-card-bg",
            Self::CardForeground => "tp-diagram-card-fg",
            Self::Border => "tp-diagram-border",
            Self::Accent => "tp-diagram-accent",
        }
    }
}

/// Diagram units to canvas pixels and back, for one moment's zoom and
/// scroll. The scrolled area runs half a canvas past the diagram on each
/// side, so any part of it, small diagram or large, can be scrolled to
/// the middle, and a card moved past the edge never shifts the others.
#[derive(Debug, Clone, Copy)]
pub(crate) struct View {
    pub extent: Rect,
    pub zoom: f64,
    pub scroll_x: f64,
    pub scroll_y: f64,
    pub pad_x: f64,
    pub pad_y: f64,
}

impl View {
    pub(crate) fn new(extent: Option<Rect>, zoom: f64, size: (f64, f64), scroll: (f64, f64)) -> Self {
        let extent = extent.unwrap_or(Rect {
            x: 0.0,
            y: 0.0,
            width: 0.0,
            height: 0.0,
        });
        Self {
            extent,
            zoom,
            scroll_x: scroll.0,
            scroll_y: scroll.1,
            pad_x: (size.0 / 2.0).max(0.0),
            pad_y: (size.1 / 2.0).max(0.0),
        }
    }

    pub(crate) fn content_width(self) -> f64 {
        self.extent.width * self.zoom + 2.0 * self.pad_x
    }

    pub(crate) fn content_height(self) -> f64 {
        self.extent.height * self.zoom + 2.0 * self.pad_y
    }

    pub(crate) fn to_widget(self, x: f64, y: f64) -> (f64, f64) {
        (
            (x - self.extent.x) * self.zoom - self.scroll_x + self.pad_x,
            (y - self.extent.y) * self.zoom - self.scroll_y + self.pad_y,
        )
    }

    pub(crate) fn to_scene(self, x: f64, y: f64) -> Point {
        Point {
            x: (x + self.scroll_x - self.pad_x) / self.zoom + self.extent.x,
            y: (y + self.scroll_y - self.pad_y) / self.zoom + self.extent.y,
        }
    }

    /// The scroll that puts the middle of the diagram in the middle of
    /// the canvas.
    pub(crate) fn centred(self) -> (f64, f64) {
        (
            self.extent.width * self.zoom / 2.0,
            self.extent.height * self.zoom / 2.0,
        )
    }

    /// The scroll that puts the diagram's top left corner at the canvas's.
    pub(crate) fn top_left(self) -> (f64, f64) {
        (self.pad_x, self.pad_y)
    }

    /// The part of the diagram a canvas of this size shows.
    pub(crate) fn visible(self, width: f64, height: f64) -> Rect {
        let corner = self.to_scene(0.0, 0.0);
        Rect {
            x: corner.x,
            y: corner.y,
            width: width / self.zoom,
            height: height / self.zoom,
        }
    }

    /// The scroll that puts diagram point `point` at canvas pixel `at`.
    fn scroll_for(self, point: Point, at: (f64, f64)) -> (f64, f64) {
        (
            (point.x - self.extent.x) * self.zoom + self.pad_x - at.0,
            (point.y - self.extent.y) * self.zoom + self.pad_y - at.1,
        )
    }
}

impl Default for DiagramCanvas {
    fn default() -> Self {
        Self::new()
    }
}

impl DiagramCanvas {
    pub(crate) fn new() -> Self {
        glib::Object::new()
    }

    /// Show `diagram`. With `kept`, each table keeps the place it had and
    /// a table new since then goes to the right of the others; without,
    /// the automatic layout places every table. The first diagram picks
    /// its zoom; one read again keeps the zoom and scroll there were.
    pub(crate) fn set_diagram(&self, diagram: SchemaDiagram, kept: Option<HashMap<String, Point>>) {
        let imp = self.imp();
        let selected = self.selected_table();
        let first = !self.has_diagram();
        // The keyboard stays on the same table in the new diagram. GTK 4.22
        // leaks a focused widget that is unparented, so the focus leaves
        // the old one first.
        let had_focus = crate::ui::a11y::holds_focus(self);
        // A drag names a card by its place in the old diagram.
        imp.drag.replace(None);
        if had_focus && let Some(window) = self.root().and_downcast::<gtk::Window>() {
            GtkWindowExt::set_focus(&window, None::<&gtk::Widget>);
        }
        let previous_area = imp.content.take().map(|old| {
            for node in old.nodes {
                node.unparent();
            }
            old.extent
        });
        let context = self.pango_context();
        let texts: Vec<CardText> = diagram
            .tables
            .iter()
            .map(|table| CardText::lay_out(&context, table))
            .collect();
        let cards = texts
            .iter()
            .map(|text| Card {
                at: Point { x: 0.0, y: 0.0 },
                shape: text.shape,
            })
            .collect();
        let count = diagram.tables.len();
        let nodes = (0..count)
            .map(|at| {
                let label = diagram.tables[at].table.name.as_str();
                let node = DiagramNode::new(at, label, &table_description(&diagram, at), count);
                node.set_parent(self);
                node
            })
            .collect();
        let mut content = Content {
            diagram,
            texts,
            cards,
            edges: Vec::new(),
            order: (0..count).collect(),
            nodes,
            extent: Rect {
                x: 0.0,
                y: 0.0,
                width: 1.0,
                height: 1.0,
            },
            moved: false,
        };
        let fresh = match kept {
            Some(kept) => !place_kept(&mut content, &kept),
            None => true,
        };
        if fresh {
            content.arrange();
        }
        content.route_all();
        content.measure_extent();
        if let Some(area) = previous_area {
            content.extent = area;
        }
        let reselect = selected.and_then(|table| content.diagram.position_of(&table));
        imp.content.replace(Some(content));
        imp.selected.set(None);
        if first {
            imp.pending_fit.set(true);
        } else {
            self.grow_area();
        }
        self.select(reselect);
        if had_focus && let Some(index) = reselect.or((count > 0).then_some(0)) {
            imp.quiet_focus.set(true);
            self.focus_table(index);
            imp.quiet_focus.set(false);
        }
        self.queue_resize();
        self.queue_draw();
    }

    #[cfg(test)]
    pub(crate) fn palette(&self) -> super::palette::Palette {
        self.imp().palette()
    }

    pub(crate) fn has_diagram(&self) -> bool {
        self.imp().content.borrow().is_some()
    }

    /// Where every table is, by name, once the user has moved one: a
    /// refresh and a restore put them back there.
    pub(crate) fn kept_places(&self) -> Option<HashMap<String, Point>> {
        let content = self.imp().content.borrow();
        let content = content.as_ref().filter(|content| content.moved)?;
        Some(
            content
                .diagram
                .tables
                .iter()
                .zip(&content.cards)
                .map(|(table, card)| (table.table.name.clone(), card.at))
                .collect(),
        )
    }

    #[cfg(test)]
    pub(crate) fn card_position(&self, index: usize) -> Point {
        self.imp()
            .content
            .borrow()
            .as_ref()
            .and_then(|content| content.cards.get(index))
            .map_or(Point { x: 0.0, y: 0.0 }, |card| card.at)
    }

    pub(crate) fn table(&self, index: usize) -> Option<TableRef> {
        let content = self.imp().content.borrow();
        content
            .as_ref()?
            .diagram
            .tables
            .get(index)
            .map(|table| table.table.clone())
    }

    pub(crate) fn table_count(&self) -> usize {
        self.imp()
            .content
            .borrow()
            .as_ref()
            .map_or(0, |content| content.diagram.tables.len())
    }

    pub(crate) fn selected(&self) -> Option<usize> {
        self.imp().selected.get()
    }

    pub(crate) fn selected_table(&self) -> Option<TableRef> {
        self.table(self.selected()?)
    }

    /// The widget a screen reader and the keyboard meet for `index`.
    pub(crate) fn node(&self, index: usize) -> Option<DiagramNode> {
        self.imp().content.borrow().as_ref()?.nodes.get(index).cloned()
    }

    pub(crate) fn select(&self, index: Option<usize>) {
        let imp = self.imp();
        let index = index.filter(|&at| at < self.table_count());
        if imp.selected.get() == index {
            return;
        }
        let previous = imp.selected.replace(index);
        for at in [previous, index].into_iter().flatten() {
            if let Some(node) = self.node(at) {
                node.set_selected(Some(at) == index);
            }
        }
        if let Some(at) = index {
            self.raise(at);
        }
        self.queue_draw();
        self.emit_by_name::<()>("selection-changed", &[]);
    }

    pub(crate) fn focus_table(&self, index: usize) {
        if let Some(node) = self.node(index) {
            self.select(Some(index));
            node.grab_focus();
        }
    }

    fn raise(&self, index: usize) {
        if let Some(content) = self.imp().content.borrow_mut().as_mut() {
            content.order.retain(|&at| at != index);
            content.order.push(index);
        }
    }

    pub(crate) fn zoom(&self) -> f64 {
        self.imp().zoom.get()
    }

    /// Zoom to `zoom`, keeping the diagram point under `anchor`, in canvas
    /// pixels, where it is; the middle of the canvas without one.
    pub(crate) fn set_zoom(&self, zoom: f64, anchor: Option<(f64, f64)>) {
        let imp = self.imp();
        let zoom = zoom::clamp(zoom);
        if (zoom - imp.zoom.get()).abs() < 1e-9 {
            return;
        }
        let (width, height) = (f64::from(self.width()), f64::from(self.height()));
        let anchor = anchor.unwrap_or((width / 2.0, height / 2.0));
        let point = imp.view().to_scene(anchor.0, anchor.1);
        imp.zoom.set(zoom);
        let scroll = imp.view().scroll_for(point, anchor);
        imp.configure_adjustments(width, height, Some(scroll));
        self.queue_allocate();
        self.queue_draw();
        self.emit_by_name::<()>("zoom-changed", &[]);
    }

    pub(crate) fn zoom_in(&self) {
        self.set_zoom(zoom::step_in(self.zoom()), None);
    }

    pub(crate) fn zoom_out(&self) {
        self.set_zoom(zoom::step_out(self.zoom()), None);
    }

    pub(crate) fn zoom_reset(&self) {
        self.set_zoom(1.0, None);
    }

    pub(crate) fn zoom_fit(&self) {
        let imp = self.imp();
        let Some(bounds) = imp.content.borrow().as_ref().map(Content::bounds) else {
            return;
        };
        let (width, height) = (f64::from(self.width()), f64::from(self.height()));
        imp.zoom.set(zoom::fit((bounds.width, bounds.height), (width, height)));
        let middle = Point {
            x: bounds.x + bounds.width / 2.0,
            y: bounds.y + bounds.height / 2.0,
        };
        let scroll = imp.view().scroll_for(middle, (width / 2.0, height / 2.0));
        imp.configure_adjustments(width, height, Some(scroll));
        self.queue_allocate();
        self.queue_draw();
        self.emit_by_name::<()>("zoom-changed", &[]);
    }

    /// The zoom a new diagram opens at: whole when that is readable,
    /// else readable from its top left corner.
    pub(crate) fn open_zoom(&self, width: f64, height: f64) {
        let imp = self.imp();
        let Some(extent) = imp.content.borrow().as_ref().map(|content| content.extent) else {
            return;
        };
        let fit = zoom::fit((extent.width, extent.height), (width, height));
        let zoom = fit.max(OPENING_ZOOM);
        imp.zoom.set(zoom);
        let view = imp.view();
        let whole = extent.width * zoom <= width && extent.height * zoom <= height;
        let scroll = if whole { view.centred() } else { view.top_left() };
        imp.configure_adjustments(width, height, Some(scroll));
        // This runs inside the canvas's allocation, where the zoom label
        // must not change its size.
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            if let Some(canvas) = weak.upgrade() {
                canvas.emit_by_name::<()>("zoom-changed", &[]);
            }
        });
    }

    /// Put every table back where the automatic layout places it.
    pub(crate) fn reset_layout(&self) {
        let imp = self.imp();
        {
            let mut content = imp.content.borrow_mut();
            let Some(content) = content.as_mut() else {
                return;
            };
            content.arrange();
            content.route_all();
            content.measure_extent();
        }
        self.emit_by_name::<()>("layout-changed", &[]);
        self.zoom_fit();
        if let Some(selected) = self.selected() {
            self.scroll_to_card(selected);
        }
    }

    /// Move the selected table by `dx`, `dy` diagram units.
    pub(crate) fn move_selected(&self, dx: f64, dy: f64) {
        let Some(index) = self.selected() else {
            return;
        };
        let Some(from) = self
            .imp()
            .content
            .borrow()
            .as_ref()
            .and_then(|content| content.cards.get(index))
            .map(|card| card.at)
        else {
            return;
        };
        self.place_card(
            index,
            Point {
                x: from.x + dx,
                y: from.y + dy,
            },
        );
        self.settle_move();
        self.scroll_to_card(index);
    }

    /// Move a card while it is dragged. The scrolled area stays as it was
    /// until the drag ends.
    pub(crate) fn place_card(&self, index: usize, at: Point) {
        if let Some(content) = self.imp().content.borrow_mut().as_mut()
            && let Some(card) = content.cards.get_mut(index)
        {
            card.at = at;
            content.reroute(index);
            content.moved = true;
        }
        self.queue_allocate();
        self.queue_draw();
    }

    /// After a move: the scrolled area takes in where the card went.
    pub(crate) fn settle_move(&self) {
        self.grow_area();
        self.emit_by_name::<()>("layout-changed", &[]);
    }

    /// The scrolled area takes in what the cards and lines cover now and
    /// keeps all it held before, and the scroll moves with its corner, so
    /// nothing on screen moves: a moved card, and a refresh, leave the
    /// view where it was. Only a new layout or Best Fit moves it.
    fn grow_area(&self) {
        let imp = self.imp();
        let shift = {
            let mut content = imp.content.borrow_mut();
            let Some(content) = content.as_mut() else {
                return;
            };
            let before = content.extent;
            content.extent = union(before, content.bounds());
            (before.x - content.extent.x, before.y - content.extent.y)
        };
        let zoom = self.zoom();
        let (h, v) = imp.adjustments();
        let scroll = (
            h.map_or(0.0, |adjustment| adjustment.value()) + shift.0 * zoom,
            v.map_or(0.0, |adjustment| adjustment.value()) + shift.1 * zoom,
        );
        imp.configure_adjustments(f64::from(self.width()), f64::from(self.height()), Some(scroll));
        self.queue_resize();
        self.queue_draw();
    }

    /// Scroll so the card is on screen, if it is not.
    pub(crate) fn scroll_to_card(&self, index: usize) {
        let imp = self.imp();
        let Some(bounds) = imp
            .content
            .borrow()
            .as_ref()
            .and_then(|content| content.cards.get(index))
            .map(Card::rect)
        else {
            return;
        };
        let view = imp.view();
        let (width, height) = (f64::from(self.width()), f64::from(self.height()));
        let (left, top) = view.to_widget(bounds.x, bounds.y);
        let (right, bottom) = view.to_widget(bounds.right(), bounds.bottom());
        let margin = 24.0;
        let shift = |near: f64, far: f64, size: f64| {
            if far - near + 2.0 * margin > size || near < margin {
                near - margin
            } else if far > size - margin {
                far - size + margin
            } else {
                0.0
            }
        };
        let (dx, dy) = (shift(left, right, width), shift(top, bottom, height));
        if dx == 0.0 && dy == 0.0 {
            return;
        }
        imp.configure_adjustments(width, height, Some((view.scroll_x + dx, view.scroll_y + dy)));
        self.queue_allocate();
        self.queue_draw();
    }

    /// The card at canvas pixel (`x`, `y`).
    pub(crate) fn card_at(&self, x: f64, y: f64) -> Option<usize> {
        let imp = self.imp();
        let point = imp.view().to_scene(x, y);
        let content = imp.content.borrow();
        let content = content.as_ref()?;
        scene::hit(&content.cards, &content.order, point)
    }

    /// Where `index`'s card is on the canvas, for a menu to point at.
    pub(crate) fn card_bounds(&self, index: usize) -> Option<gdk::Rectangle> {
        let imp = self.imp();
        let bounds = imp.content.borrow().as_ref()?.cards.get(index)?.rect();
        let view = imp.view();
        let (x, y) = view.to_widget(bounds.x, bounds.y);
        Some(gdk::Rectangle::new(
            x as i32,
            y as i32,
            (bounds.width * view.zoom) as i32,
            (bounds.height * view.zoom).min(48.0) as i32,
        ))
    }

    /// Measure the text again after the font changed, and lay the tables
    /// out again unless the user placed them.
    pub(crate) fn measure_again(&self) {
        let context = self.pango_context();
        let mut guard = self.imp().content.borrow_mut();
        let Some(content) = guard.as_mut() else {
            return;
        };
        let texts: Vec<CardText> = content
            .diagram
            .tables
            .iter()
            .map(|table| CardText::lay_out(&context, table))
            .collect();
        if texts
            .iter()
            .zip(&content.texts)
            .all(|(new, old)| new.shape == old.shape)
        {
            content.texts = texts;
            return;
        }
        for (card, text) in content.cards.iter_mut().zip(&texts) {
            card.shape = text.shape;
        }
        content.texts = texts;
        if !content.moved {
            content.arrange();
        }
        content.route_all();
        content.measure_extent();
        drop(guard);
        self.queue_resize();
        self.queue_draw();
    }

    /// The whole diagram at 100%, on its background, for an export, with
    /// its size in pixels.
    pub(crate) fn render(&self) -> Option<(gsk::RenderNode, f64, f64)> {
        let imp = self.imp();
        let palette = imp.palette();
        let content = imp.content.borrow();
        let content = content.as_ref()?;
        let extent = content.bounds();
        let snapshot = gtk::Snapshot::new();
        snapshot.append_color(
            &palette.background,
            &graphene::Rect::new(0.0, 0.0, extent.width as f32, extent.height as f32),
        );
        snapshot.translate(&graphene::Point::new(-extent.x as f32, -extent.y as f32));
        let frame = Frame {
            diagram: &content.diagram,
            texts: &content.texts,
            cards: &content.cards,
            edges: &content.edges,
            order: &content.order,
            selected: None,
            focused: None,
            detail: true,
        };
        draw::draw(&snapshot, &frame, &extent, &palette);
        Some((snapshot.to_node()?, extent.width, extent.height))
    }

    pub(crate) fn connect_zoom_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "zoom-changed",
            false,
            glib::closure_local!(move |canvas: &Self| f(canvas)),
        )
    }

    pub(crate) fn connect_selection_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "selection-changed",
            false,
            glib::closure_local!(move |canvas: &Self| f(canvas)),
        )
    }

    /// The user moved a table, or put them all back.
    pub(crate) fn connect_layout_changed<F: Fn(&Self) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "layout-changed",
            false,
            glib::closure_local!(move |canvas: &Self| f(canvas)),
        )
    }

    /// A double click on a card.
    pub(crate) fn connect_table_activated<F: Fn(&Self, usize) + 'static>(&self, f: F) -> glib::SignalHandlerId {
        self.connect_closure(
            "table-activated",
            false,
            glib::closure_local!(move |canvas: &Self, index: u32| {
                f(canvas, usize::try_from(index).unwrap_or(usize::MAX));
            }),
        )
    }
}

fn union(a: Rect, b: Rect) -> Rect {
    let (x, y) = (a.x.min(b.x), a.y.min(b.y));
    Rect {
        x,
        y,
        width: a.right().max(b.right()) - x,
        height: a.bottom().max(b.bottom()) - y,
    }
}

/// A new diagram opens no smaller than this, so its text can be read.
const OPENING_ZOOM: f64 = 0.75;

/// Put each table `kept` names where it was, and the others in a column
/// right of them. False when `kept` names none of the tables, so the
/// automatic layout does better.
fn place_kept(content: &mut Content, kept: &HashMap<String, Point>) -> bool {
    let mut right = f64::NEG_INFINITY;
    let mut top = f64::INFINITY;
    let mut placed = vec![false; content.cards.len()];
    for (at, table) in content.diagram.tables.iter().enumerate() {
        if let (Some(point), Some(card)) = (kept.get(&table.table.name), content.cards.get_mut(at)) {
            card.at = *point;
            placed[at] = true;
            right = right.max(point.x + card.shape.width);
            top = top.min(point.y);
        }
    }
    if !placed.contains(&true) {
        return false;
    }
    let mut y = top;
    for (at, card) in content.cards.iter_mut().enumerate() {
        if placed[at] {
            continue;
        }
        card.at = Point {
            x: right + COLUMN_GAP,
            y,
        };
        y += card.shape.size().height + ROW_GAP;
    }
    content.moved = true;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    const EXTENT: Rect = Rect {
        x: -40.0,
        y: -40.0,
        width: 2000.0,
        height: 1500.0,
    };

    #[test]
    fn a_zoom_keeps_the_point_under_the_pointer() {
        let before = View::new(Some(EXTENT), 1.0, (800.0, 600.0), (700.0, 500.0));
        let point = before.to_scene(100.0, 50.0);
        let scroll = View::new(Some(EXTENT), 2.0, (800.0, 600.0), (0.0, 0.0)).scroll_for(point, (100.0, 50.0));

        let after = View::new(Some(EXTENT), 2.0, (800.0, 600.0), scroll);

        assert_eq!(after.to_widget(point.x, point.y), (100.0, 50.0));
        assert_eq!(point, Point { x: 360.0, y: 210.0 });
    }

    #[test]
    fn any_diagram_can_be_centred_or_shown_from_its_corner() {
        let shape = View::new(Some(EXTENT), 0.25, (800.0, 600.0), (0.0, 0.0));
        let centred = View::new(Some(EXTENT), 0.25, (800.0, 600.0), shape.centred());
        let corner = View::new(Some(EXTENT), 0.25, (800.0, 600.0), shape.top_left());

        let middle = (EXTENT.x + EXTENT.width / 2.0, EXTENT.y + EXTENT.height / 2.0);
        assert_eq!(centred.to_widget(middle.0, middle.1), (400.0, 300.0));
        assert_eq!(corner.to_widget(EXTENT.x, EXTENT.y), (0.0, 0.0));
        assert_eq!(shape.content_width(), 2000.0 * 0.25 + 800.0);
        let visible = shape.visible(800.0, 600.0);
        assert_eq!((visible.width, visible.height), (3200.0, 2400.0));
    }

    #[test]
    fn the_union_holds_both() {
        let moved = Rect {
            x: -200.0,
            y: 100.0,
            width: 100.0,
            height: 50.0,
        };

        let both = union(EXTENT, moved);

        assert_eq!(
            (both.x, both.y, both.right(), both.bottom()),
            (-200.0, -40.0, 1960.0, 1460.0)
        );
    }
}
