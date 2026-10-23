use std::cell::{Cell, RefCell};
use std::sync::OnceLock;

use glib::subclass::Signal;
use gtk4 as gtk;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, glib, graphene};

use super::canvas::{Content, Drag, Probe, View};
use super::draw::{self, DETAIL_ZOOM, Frame};
use super::node::DiagramNode;
use super::palette::{Palette, ThemeColors};

#[derive(glib::Properties)]
#[properties(wrapper_type = super::canvas::DiagramCanvas)]
pub struct DiagramCanvas {
    #[property(override_interface = gtk::Scrollable, get, set = Self::set_hadjustment)]
    hadjustment: RefCell<Option<gtk::Adjustment>>,
    #[property(override_interface = gtk::Scrollable, get, set = Self::set_vadjustment)]
    vadjustment: RefCell<Option<gtk::Adjustment>>,
    #[property(override_interface = gtk::Scrollable, get, set)]
    hscroll_policy: Cell<gtk::ScrollablePolicy>,
    #[property(override_interface = gtk::Scrollable, get, set)]
    vscroll_policy: Cell<gtk::ScrollablePolicy>,

    pub(super) content: RefCell<Option<Content>>,
    pub(super) zoom: Cell<f64>,
    pub(super) selected: Cell<Option<usize>>,
    pub(super) drag: RefCell<Option<Drag>>,
    /// Where the pointer last was, which Ctrl+scroll zooms around.
    pub(super) pointer: Cell<Option<(f64, f64)>>,
    /// The zoom when a pinch began.
    pub(super) pinch: Cell<Option<f64>>,
    /// A new diagram picks its zoom once the canvas knows its size.
    pub(super) pending_fit: Cell<bool>,
    /// The focus moves without the keyboard, from a click or a refresh,
    /// so the view stays where the user left it.
    pub(super) quiet_focus: Cell<bool>,
    pub(super) popover: RefCell<Option<gtk::PopoverMenu>>,
    pub(super) probes: RefCell<Vec<(Probe, gtk::Widget)>>,
    configuring: Cell<bool>,
    adjustment_handlers: RefCell<Vec<(gtk::Adjustment, glib::SignalHandlerId)>>,
    style_handlers: RefCell<Vec<glib::SignalHandlerId>>,
    window_handler: RefCell<Option<(glib::WeakRef<gtk::Window>, glib::SignalHandlerId)>>,
}

impl Default for DiagramCanvas {
    fn default() -> Self {
        Self {
            hadjustment: RefCell::default(),
            vadjustment: RefCell::default(),
            hscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
            vscroll_policy: Cell::new(gtk::ScrollablePolicy::Minimum),
            content: RefCell::default(),
            zoom: Cell::new(1.0),
            selected: Cell::default(),
            drag: RefCell::default(),
            pointer: Cell::default(),
            pinch: Cell::default(),
            pending_fit: Cell::default(),
            quiet_focus: Cell::default(),
            popover: RefCell::default(),
            probes: RefCell::default(),
            configuring: Cell::default(),
            adjustment_handlers: RefCell::default(),
            style_handlers: RefCell::default(),
            window_handler: RefCell::default(),
        }
    }
}

#[glib::object_subclass]
impl ObjectSubclass for DiagramCanvas {
    const NAME: &'static str = "TableProDiagramCanvas";
    type Type = super::canvas::DiagramCanvas;
    type ParentType = gtk::Widget;
    type Interfaces = (gtk::Scrollable,);

    fn class_init(klass: &mut Self::Class) {
        klass.set_css_name("tp-diagram-canvas");
        klass.set_accessible_role(gtk::AccessibleRole::List);
    }
}

#[glib::derived_properties]
impl ObjectImpl for DiagramCanvas {
    fn constructed(&self) {
        self.parent_constructed();
        let canvas = self.obj();
        canvas.set_overflow(gtk::Overflow::Hidden);
        let probes = Probe::ALL
            .iter()
            .map(|&probe| {
                let widget = gtk::Box::new(gtk::Orientation::Horizontal, 0);
                widget.add_css_class(probe.css_class());
                widget.set_visible(false);
                widget.set_parent(&*canvas);
                (probe, widget.upcast::<gtk::Widget>())
            })
            .collect();
        self.probes.replace(probes);
        super::canvas_input::install(&canvas);
        let manager = libadwaita::StyleManager::default();
        let weak = canvas.downgrade();
        let redraw = move || {
            if let Some(canvas) = weak.upgrade() {
                canvas.queue_draw();
            }
        };
        let handlers = ["dark", "high-contrast", "accent-color-rgba"]
            .into_iter()
            .map(|property| {
                let redraw = redraw.clone();
                manager.connect_notify_local(Some(property), move |_, _| redraw())
            })
            .collect();
        self.style_handlers.replace(handlers);
    }

    fn signals() -> &'static [Signal] {
        static SIGNALS: OnceLock<Vec<Signal>> = OnceLock::new();
        SIGNALS.get_or_init(|| {
            vec![
                Signal::builder("zoom-changed").build(),
                Signal::builder("selection-changed").build(),
                Signal::builder("layout-changed").build(),
                Signal::builder("table-activated")
                    .param_types([u32::static_type()])
                    .build(),
            ]
        })
    }

    fn dispose(&self) {
        let manager = libadwaita::StyleManager::default();
        for handler in self.style_handlers.take() {
            manager.disconnect(handler);
        }
        self.disconnect_window();
        for (adjustment, handler) in self.adjustment_handlers.take() {
            adjustment.disconnect(handler);
        }
        if let Some(popover) = self.popover.take() {
            popover.unparent();
        }
        if let Some(content) = self.content.take() {
            for node in content.nodes {
                node.unparent();
            }
        }
        for (_, probe) in self.probes.take() {
            probe.unparent();
        }
    }
}

impl WidgetImpl for DiagramCanvas {
    fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
        let view = self.view();
        let natural = match orientation {
            gtk::Orientation::Horizontal => view.content_width(),
            _ => view.content_height(),
        };
        (0, natural.ceil().min(f64::from(i32::MAX)) as i32, -1, -1)
    }

    fn size_allocate(&self, width: i32, height: i32, _baseline: i32) {
        let (width, height) = (f64::from(width), f64::from(height));
        if self.pending_fit.get() && width > 0.0 && height > 0.0 {
            self.pending_fit.set(false);
            self.obj().open_zoom(width, height);
        }
        self.configure_adjustments(width, height, None);
        self.allocate_nodes();
        if let Some(popover) = self.popover.borrow().as_ref() {
            popover.present();
        }
    }

    fn snapshot(&self, snapshot: &gtk::Snapshot) {
        let canvas = self.obj();
        let (width, height) = (f64::from(canvas.width()), f64::from(canvas.height()));
        let palette = self.palette();
        snapshot.append_color(
            &palette.background,
            &graphene::Rect::new(0.0, 0.0, width as f32, height as f32),
        );
        let content = self.content.borrow();
        let Some(content) = content.as_ref() else {
            return;
        };
        let view = self.view();
        let zoom = self.zoom.get();
        snapshot.save();
        snapshot.translate(&graphene::Point::new(
            (view.pad_x - view.scroll_x) as f32,
            (view.pad_y - view.scroll_y) as f32,
        ));
        snapshot.scale(zoom as f32, zoom as f32);
        snapshot.translate(&graphene::Point::new(
            -content.extent.x as f32,
            -content.extent.y as f32,
        ));
        let frame = Frame {
            diagram: &content.diagram,
            texts: &content.texts,
            cards: &content.cards,
            edges: &content.edges,
            order: &content.order,
            selected: self.selected.get(),
            focused: self.focus_ring(content),
            detail: zoom >= DETAIL_ZOOM,
        };
        draw::draw(snapshot, &frame, &view.visible(width, height), &palette);
        snapshot.restore();
    }

    fn set_focus_child(&self, child: Option<&gtk::Widget>) {
        self.parent_set_focus_child(child);
        let Some(node) = child.and_then(|child| child.downcast_ref::<DiagramNode>()) else {
            self.obj().queue_draw();
            return;
        };
        let canvas = self.obj();
        canvas.select(Some(node.index()));
        if !self.quiet_focus.replace(false) {
            canvas.scroll_to_card(node.index());
        }
        canvas.queue_draw();
    }

    fn system_setting_changed(&self, setting: &gtk::SystemSetting) {
        self.parent_system_setting_changed(setting);
        if matches!(
            setting,
            gtk::SystemSetting::FontName | gtk::SystemSetting::Dpi | gtk::SystemSetting::FontConfig
        ) {
            self.obj().measure_again();
        }
    }

    fn root(&self) {
        self.parent_root();
        let canvas = self.obj();
        if let Some(window) = canvas.root().and_downcast::<gtk::Window>() {
            let weak = canvas.downgrade();
            let handler = window.connect_focus_visible_notify(move |_| {
                if let Some(canvas) = weak.upgrade() {
                    canvas.queue_draw();
                }
            });
            self.window_handler.replace(Some((window.downgrade(), handler)));
        }
        // The window's font can differ from the default the text was
        // first measured with.
        canvas.measure_again();
    }

    fn unroot(&self) {
        self.disconnect_window();
        self.parent_unroot();
    }
}

impl ScrollableImpl for DiagramCanvas {}

impl DiagramCanvas {
    fn set_hadjustment(&self, adjustment: Option<gtk::Adjustment>) {
        self.hadjustment.replace(self.follow(adjustment));
    }

    fn set_vadjustment(&self, adjustment: Option<gtk::Adjustment>) {
        self.vadjustment.replace(self.follow(adjustment));
    }

    /// Redraw and move the cards' widgets when the scrolled window
    /// scrolls.
    fn follow(&self, adjustment: Option<gtk::Adjustment>) -> Option<gtk::Adjustment> {
        let adjustment = adjustment?;
        let weak = self.obj().downgrade();
        let handler = adjustment.connect_value_changed(move |_| {
            let Some(canvas) = weak.upgrade() else {
                return;
            };
            if !canvas.imp().configuring.get() {
                canvas.queue_allocate();
            }
            canvas.queue_draw();
        });
        self.adjustment_handlers
            .borrow_mut()
            .push((adjustment.clone(), handler));
        Some(adjustment)
    }

    fn disconnect_window(&self) {
        if let Some((window, handler)) = self.window_handler.take()
            && let Some(window) = window.upgrade()
        {
            window.disconnect(handler);
        }
    }

    pub(super) fn adjustments(&self) -> (Option<gtk::Adjustment>, Option<gtk::Adjustment>) {
        (self.hadjustment.borrow().clone(), self.vadjustment.borrow().clone())
    }

    /// The transform from the diagram to the canvas as it stands.
    pub(super) fn view(&self) -> View {
        let canvas = self.obj();
        let (h, v) = self.adjustments();
        let extent = self.content.borrow().as_ref().map(|content| content.extent);
        View::new(
            extent,
            self.zoom.get(),
            (f64::from(canvas.width()), f64::from(canvas.height())),
            (
                h.map_or(0.0, |adjustment| adjustment.value()),
                v.map_or(0.0, |adjustment| adjustment.value()),
            ),
        )
    }

    /// Fit the scrolled area to the diagram at the zoom, and scroll to
    /// `values` when given, else keep the scroll within the new bounds.
    pub(super) fn configure_adjustments(&self, width: f64, height: f64, values: Option<(f64, f64)>) {
        let view = self.view();
        let (h, v) = self.adjustments();
        self.configuring.set(true);
        for (adjustment, content, page, wanted) in [
            (h, view.content_width(), width, values.map(|values| values.0)),
            (v, view.content_height(), height, values.map(|values| values.1)),
        ] {
            let Some(adjustment) = adjustment else {
                continue;
            };
            let upper = content.max(page);
            let value = wanted.unwrap_or_else(|| adjustment.value());
            adjustment.configure(
                value.clamp(0.0, (upper - page).max(0.0)),
                0.0,
                upper,
                page * 0.1,
                page * 0.9,
                page,
            );
        }
        self.configuring.set(false);
    }

    /// Put each card's widget where its card is drawn.
    pub(super) fn allocate_nodes(&self) {
        let view = self.view();
        let content = self.content.borrow();
        let Some(content) = content.as_ref() else {
            return;
        };
        for node in &content.nodes {
            let Some(card) = content.cards.get(node.index()) else {
                continue;
            };
            let bounds = card.rect();
            let (x, y) = view.to_widget(bounds.x, bounds.y);
            let width = (bounds.width * view.zoom).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
            let height = (bounds.height * view.zoom).ceil().clamp(1.0, f64::from(i32::MAX)) as i32;
            let transform = gtk4::gsk::Transform::new().translate(&graphene::Point::new(x as f32, y as f32));
            // GTK asks that a widget be measured before it is allocated.
            let _ = node.preferred_size();
            node.allocate(width, height, -1, Some(transform));
        }
    }

    /// The colours of the theme the canvas is in. Each probe's `color` is
    /// one of libadwaita's colour variables, from the app's stylesheet.
    pub(super) fn palette(&self) -> Palette {
        let canvas = self.obj();
        let fallback = canvas.color();
        let color = |wanted: Probe| {
            self.probes
                .borrow()
                .iter()
                .find(|(probe, _)| *probe == wanted)
                .map_or(fallback, |(_, widget)| widget.color())
        };
        Palette::from_theme(ThemeColors {
            window_bg: color(Probe::WindowBackground),
            card_bg: color(Probe::CardBackground),
            card_fg: color(Probe::CardForeground),
            border: color(Probe::Border),
            accent: color(Probe::Accent),
        })
    }

    /// The card whose widget holds the keyboard focus, while the window
    /// shows where the focus is.
    fn focus_ring(&self, content: &Content) -> Option<usize> {
        let canvas = self.obj();
        let window = canvas.root().and_downcast::<gtk::Window>()?;
        if !window.gets_focus_visible() {
            return None;
        }
        let focus = gtk::prelude::GtkWindowExt::focus(&window)?;
        content
            .nodes
            .iter()
            .find(|node| node.upcast_ref::<gtk::Widget>() == &focus)
            .map(DiagramNode::index)
    }
}

/// The pointer's modifiers, to tell Ctrl+scroll from a scroll.
pub(super) fn has_primary_modifier(state: gdk::ModifierType) -> bool {
    state.contains(gdk::ModifierType::CONTROL_MASK)
}
