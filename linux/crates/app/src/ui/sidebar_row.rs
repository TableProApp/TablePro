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
}

#[derive(Debug)]
pub enum SidebarRowOutput {
    /// Ctrl+click or right-click "Open in new tab" — App always appends a
    /// new tab even if the same table is already open. Plain click /
    /// Enter activation does NOT flow through here; it's handled at the
    /// parent ListBox via the `row-activated` signal, which is the only
    /// GTK signal that fires for both mouse and keyboard activation.
    OpenInNewTab { schema: Option<String>, name: String },
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

        // Right-click → context menu with a single "Open in new tab" entry.
        // Same pattern as crates/app/src/ui/grid.rs::attach_context_menu —
        // PopoverMenu fed by a gio::Menu, action group on the row widget.
        let menu = gtk::gio::Menu::new();
        menu.append(
            Some(&crate::tr!("Open in new tab")),
            Some("sidebar-row.open-in-new-tab"),
        );
        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_has_arrow(true);
        popover.set_parent(&root);

        let group = gtk::gio::SimpleActionGroup::new();
        let sender_for_action = sender.clone();
        let open_action = gtk::gio::ActionEntry::builder("open-in-new-tab")
            .activate(move |_, _, _| sender_for_action.input(SidebarRowMsg::OpenInNewTab))
            .build();
        group.add_action_entries([open_action]);
        root.insert_action_group("sidebar-row", Some(&group));

        let right_click = gtk::GestureClick::builder().button(3).build();
        let popover_for_gesture = popover.clone();
        right_click.connect_pressed(move |g, _, x, y| {
            g.set_state(gtk::EventSequenceState::Claimed);
            popover_for_gesture.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
            popover_for_gesture.popup();
        });
        root.add_controller(right_click);

        // Keyboard menu key opens the same context menu.
        let menu_shortcut = gtk::Shortcut::builder()
            .trigger(&gtk::ShortcutTrigger::parse_string("Menu").expect("valid trigger"))
            .action(&gtk::CallbackAction::new(move |_, _| {
                popover.popup();
                glib::Propagation::Stop
            }))
            .build();
        let shortcut_controller = gtk::ShortcutController::new();
        shortcut_controller.add_shortcut(menu_shortcut);
        root.add_controller(shortcut_controller);

        widgets
    }

    fn update(&mut self, msg: Self::Input, sender: FactorySender<Self>) {
        match msg {
            SidebarRowMsg::OpenInNewTab => {
                let _ = sender.output(SidebarRowOutput::OpenInNewTab {
                    schema: self.info.schema.clone(),
                    name: self.info.name.clone(),
                });
            }
        }
    }
}
