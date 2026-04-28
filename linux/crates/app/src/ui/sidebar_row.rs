use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::gtk;
use relm4::gtk::gdk;
use relm4::gtk::glib;
use relm4::gtk::pango;
use relm4::gtk::prelude::*;

use tablepro_core::TableInfo;

#[derive(Debug)]
pub struct SidebarRow {
    pub info: TableInfo,
}

#[derive(Debug)]
pub enum SidebarRowMsg {
    OpenInNewTab,
    EditStructure,
    DropTable,
}

#[derive(Debug)]
pub enum SidebarRowOutput {
    /// Ctrl+click or right-click "Open in new tab" — App always appends a
    /// new tab even if the same table is already open. Plain click /
    /// Enter activation does NOT flow through here; it's handled at the
    /// parent ListBox via the `row-activated` signal, which is the only
    /// GTK signal that fires for both mouse and keyboard activation.
    OpenInNewTab { schema: Option<String>, name: String },
    /// Right-click "Edit Structure" → opens an Edit-mode Structure tab
    /// for this table.
    EditStructure { schema: Option<String>, name: String },
    /// Right-click "Drop Table…" → App presents the AdwAlertDialog
    /// confirmation; on confirm runs DROP TABLE and closes any open
    /// tabs for the dropped table.
    DropTable { schema: Option<String>, name: String },
}

#[relm4::factory(pub)]
impl FactoryComponent for SidebarRow {
    type Init = TableInfo;
    type Input = SidebarRowMsg;
    type Output = SidebarRowOutput;
    type CommandOutput = ();
    type ParentWidget = gtk::ListBox;

    view! {
        // Compact navigation row matching GNOME Files / Builder density
        // (~36-40px). AdwActionRow was the wrong widget here — it's for
        // settings entries (title + subtitle + suffix) and forces
        // ~50px height even with single-line content. The parent
        // ListBox carries the `.navigation-sidebar` style class which
        // does the rest of the visual work.
        gtk::ListBoxRow {
            set_activatable: true,
            // No connect_activate here: gtk::ListBoxRow::activate is a
            // keybinding signal that fires only on Enter, not on mouse
            // click. The unified handler lives on the parent ListBox
            // (`row-activated`), which fires for both keyboard and mouse.
            //
            // Stash the table name for filter_func / sync_sidebar_selection
            // / row-activated lookup. widget-name is unused for CSS in
            // this app, so no styling collision risk.
            set_widget_name: &self.info.name,

            #[wrap(Some)]
            set_child = &gtk::Box {
                set_orientation: gtk::Orientation::Horizontal,
                set_spacing: 12,
                set_margin_start: 12,
                set_margin_end: 12,
                set_margin_top: 6,
                set_margin_bottom: 6,

                gtk::Image {
                    set_icon_name: Some("view-list-symbolic"),
                    set_pixel_size: 16,
                },

                gtk::Label {
                    set_label: &self.info.name,
                    set_xalign: 0.0,
                    set_hexpand: true,
                    set_ellipsize: pango::EllipsizeMode::End,
                },
            },
        }
    }

    fn init_model(info: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        Self { info }
    }

    fn init_widgets(
        &mut self,
        _index: &DynamicIndex,
        root: Self::Root,
        _returned_widget: &<Self::ParentWidget as relm4::factory::FactoryView>::ReturnedWidget,
        sender: FactorySender<Self>,
    ) -> Self::Widgets {
        let widgets = view_output!();

        // Tooltip surfaces the fully-qualified name (`schema.table`)
        // for multi-schema connections so the user can disambiguate
        // sibling tables without a tab open. Single-schema connections
        // get a plain table-name tooltip — redundant with the visible
        // label, but harmless and keeps screen-reader output uniform.
        let tooltip = match self.info.schema.as_deref().filter(|s| !s.is_empty()) {
            Some(schema) => format!("{schema}.{}", self.info.name),
            None => self.info.name.clone(),
        };
        root.set_tooltip_text(Some(&tooltip));

        // Ctrl+click → "Open in new tab". A button=1 GestureClick fires
        // before the ListBoxRow's own activate signal, so we can intercept
        // and short-circuit when CONTROL is held; without claiming the
        // gesture, normal clicks fall through to connect_activate.
        let click_gesture = gtk::GestureClick::builder().button(1).build();
        let sender_for_ctrl = sender.clone();
        click_gesture.connect_pressed(move |gesture, _, _, _| {
            let state = gesture.current_event_state();
            if state.contains(gdk::ModifierType::CONTROL_MASK) {
                gesture.set_state(gtk::EventSequenceState::Claimed);
                sender_for_ctrl.input(SidebarRowMsg::OpenInNewTab);
            }
        });
        root.add_controller(click_gesture);

        // GtkPopoverMenu must be parented eagerly at row init.
        //
        // Why: PopoverMenu resolves "namespace.action" names through
        // an internal GtkActionMuxer that snapshots the parent's
        // action-group observation chain at set_parent() time. A
        // lazy set_parent inside the gesture handler creates the
        // popover in a standalone muxer scope; later insert_action_group
        // calls on either the popover or the row are invisible to the
        // muxer. The menu still renders (model is read directly) but
        // every item-click is silently dropped because lookup finds
        // no group.
        //
        // Defence against the "PopoverMenu destroyed while visible"
        // warning that motivated the (failed) lazy refactor: a
        // connect_unmap on the row pops down the menu before the
        // factory finalises the widget.
        let menu = gtk::gio::Menu::new();
        let open_section = gtk::gio::Menu::new();
        open_section.append(
            Some(&crate::tr!("Open in new tab")),
            Some("sidebar-row.open-in-new-tab"),
        );
        menu.append_section(None, &open_section);
        let structure_section = gtk::gio::Menu::new();
        structure_section.append(Some(&crate::tr!("Edit Structure")), Some("sidebar-row.edit-structure"));
        menu.append_section(None, &structure_section);
        let mutate_section = gtk::gio::Menu::new();
        mutate_section.append(Some(&crate::tr!("Drop Table\u{2026}")), Some("sidebar-row.drop-table"));
        menu.append_section(None, &mutate_section);

        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_has_arrow(true);
        popover.set_parent(&root);

        // Action group on the row (same widget the popover is
        // parented to). The muxer walks up from the popover surface
        // through its set_parent anchor; the row is the first widget
        // in that chain that holds an action group.
        let group = gtk::gio::SimpleActionGroup::new();
        let sender_open = sender.clone();
        let open_action = gtk::gio::ActionEntry::builder("open-in-new-tab")
            .activate(move |_, _, _| sender_open.input(SidebarRowMsg::OpenInNewTab))
            .build();
        let sender_edit = sender.clone();
        let edit_action = gtk::gio::ActionEntry::builder("edit-structure")
            .activate(move |_, _, _| sender_edit.input(SidebarRowMsg::EditStructure))
            .build();
        let sender_drop = sender.clone();
        let drop_action = gtk::gio::ActionEntry::builder("drop-table")
            .activate(move |_, _, _| sender_drop.input(SidebarRowMsg::DropTable))
            .build();
        group.add_action_entries([open_action, edit_action, drop_action]);
        root.insert_action_group("sidebar-row", Some(&group));

        // Defence against the factory-clears-row-while-menu-is-open
        // race: if the row is being removed from the view, the menu
        // pops down before disposal so the popover doesn't get
        // finalised mid-display.
        let popover_for_unmap = popover.clone();
        root.connect_unmap(move |_| {
            popover_for_unmap.popdown();
        });

        let right_click = gtk::GestureClick::builder().button(3).build();
        let popover_for_right = popover.clone();
        right_click.connect_pressed(move |g, _, x, y| {
            g.set_state(gtk::EventSequenceState::Claimed);
            popover_for_right.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover_for_right.popup();
        });
        root.add_controller(right_click);

        // Keyboard Menu key opens the same context menu, anchored to
        // the row centre (no pointer position).
        let popover_for_menu = popover;
        let menu_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Menu").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                popover_for_menu.popup();
                glib::Propagation::Stop
            }))
            .build();
        let shortcut_controller = gtk::ShortcutController::new();
        shortcut_controller.add_shortcut(menu_shortcut);
        root.add_controller(shortcut_controller);

        widgets
    }

    fn update(&mut self, msg: Self::Input, sender: FactorySender<Self>) {
        tracing::trace!(
            target: "tablepro_app::sidebar_row",
            table = %self.info.name,
            ?msg,
            "input"
        );
        match msg {
            SidebarRowMsg::OpenInNewTab => {
                let _ = sender.output(SidebarRowOutput::OpenInNewTab {
                    schema: self.info.schema.clone(),
                    name: self.info.name.clone(),
                });
            }
            SidebarRowMsg::EditStructure => {
                let _ = sender.output(SidebarRowOutput::EditStructure {
                    schema: self.info.schema.clone(),
                    name: self.info.name.clone(),
                });
            }
            SidebarRowMsg::DropTable => {
                let _ = sender.output(SidebarRowOutput::DropTable {
                    schema: self.info.schema.clone(),
                    name: self.info.name.clone(),
                });
            }
        }
    }
}
