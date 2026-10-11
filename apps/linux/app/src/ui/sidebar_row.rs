use relm4::factory::{DynamicIndex, FactoryComponent, FactorySender};
use relm4::gtk;
use relm4::gtk::gdk;
use relm4::gtk::glib;
use relm4::gtk::pango;
use relm4::gtk::prelude::*;

use tablepro_core::TableInfo;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SidebarObjectKind {
    Table,
    View,
    Group,
}

#[derive(Debug, Clone)]
pub struct GroupInit {
    pub label: String,
    pub count: usize,
    pub collapsed: bool,
    pub actions: bool,
}

#[derive(Debug, Clone)]
pub struct SidebarRowInit {
    pub info: TableInfo,
    pub kind: SidebarObjectKind,
    pub depth: u8,
    pub group: Option<GroupInit>,
}

fn chevron_icon(collapsed: bool) -> &'static str {
    if collapsed {
        "pan-end-symbolic"
    } else {
        "pan-down-symbolic"
    }
}

fn sidebar_icon(kind: SidebarObjectKind) -> &'static str {
    match kind {
        SidebarObjectKind::Table => "view-list-symbolic",
        SidebarObjectKind::View => "view-paged-symbolic",
        SidebarObjectKind::Group => "folder-symbolic",
    }
}

#[derive(Debug)]
pub struct SidebarRow {
    pub info: TableInfo,
    kind: SidebarObjectKind,
    depth: u8,
    group: Option<GroupInit>,
    row: Option<gtk::ListBoxRow>,
    chevron: gtk::Image,
    new_table_button: gtk::Button,
    csv_button: gtk::Button,
    open_button: gtk::Button,
    /// The eagerly-parented context-menu popover. Held on the model
    /// so `shutdown` can `unparent()` it before the row's root widget
    /// is finalized — without this, GTK warns
    /// "Finalizing widget, but it still has children left" whenever
    /// the sidebar rebuilds.
    popover: Option<gtk::PopoverMenu>,
}

#[derive(Debug)]
pub enum SidebarRowMsg {
    Open,
    OpenInNewTab,
    EditStructure,
    ShowCreateTable,
    ImportCsv,
    DropTable,
    SetCollapsed(bool),
    NewTable,
    TableFromCsv,
}

#[derive(Debug)]
pub enum SidebarRowOutput {
    NewTable {
        schema: Option<String>,
    },
    TableFromCsv {
        schema: Option<String>,
    },
    Open {
        schema: Option<String>,
        name: String,
    },
    /// Ctrl+click or right-click "Open in new tab" — App always appends a
    /// new tab even if the same table is already open. Plain click /
    /// Enter activation does NOT flow through here; it's handled at the
    /// parent ListBox via the `row-activated` signal, which is the only
    /// GTK signal that fires for both mouse and keyboard activation.
    OpenInNewTab {
        schema: Option<String>,
        name: String,
    },
    /// Right-click "Edit Structure" → opens an Edit-mode Structure tab
    /// for this table.
    EditStructure {
        schema: Option<String>,
        name: String,
    },
    /// Right-click "Show CREATE TABLE" → App synthesises the full
    /// CREATE statement (columns + indexes + foreign keys) and opens
    /// it in a fresh editor tab. Useful for schema export, sharing,
    /// or just reading the canonical DDL without going through pg_dump.
    ShowCreateTable {
        schema: Option<String>,
        name: String,
    },
    /// Right-click "Drop Table…" → App presents the AdwAlertDialog
    /// confirmation; on confirm runs DROP TABLE and closes any open
    /// tabs for the dropped table.
    /// Right-click "Import CSV…" → App reads the file, asks the user how
    /// to map its fields, and loads it into this table.
    ImportCsv {
        schema: Option<String>,
        name: String,
    },
    DropTable {
        schema: Option<String>,
        name: String,
    },
}

#[relm4::factory(pub)]
impl FactoryComponent for SidebarRow {
    type Init = SidebarRowInit;
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
                // Icon-to-label spacing matches GtkPlacesSidebar's
                // ~8px standard. 12 was loose enough to read as two
                // separate columns rather than one labelled icon.
                set_spacing: 8,
                set_margin_start: 12 + 14 * i32::from(self.depth),
                set_margin_end: 12,
                set_margin_top: 6,
                set_margin_bottom: 6,

                append: &self.chevron,

                gtk::Image {
                    set_icon_name: Some(sidebar_icon(self.kind)),
                    set_pixel_size: 16,
                    set_visible: self.group.is_none(),
                },

                gtk::Label {
                    set_label: &self.title(),
                    set_xalign: 0.0,
                    set_hexpand: true,
                    set_ellipsize: pango::EllipsizeMode::End,
                    set_css_classes: if self.group.is_some() { &["caption-heading"] } else { &[] },
                },

                gtk::Label {
                    set_label: &self.group.as_ref().map(|group| group.count.to_string()).unwrap_or_default(),
                    set_visible: self.group.is_some(),
                    set_css_classes: &["dim-label", "caption"],
                },

                append: &self.new_table_button,
                append: &self.csv_button,
                append: &self.open_button,
            },
        }
    }

    fn init_model(init: Self::Init, _index: &DynamicIndex, _sender: FactorySender<Self>) -> Self {
        let open_label = crate::tr!("Open {name}").replace("{name}", &init.info.name);
        let open_button = gtk::Button::builder()
            .icon_name("go-next-symbolic")
            .tooltip_text(&open_label)
            .valign(gtk::Align::Center)
            .css_classes(["flat"])
            .build();
        open_button.update_property(&[gtk::accessible::Property::Label(&open_label)]);
        let actions = init.group.as_ref().is_some_and(|group| group.actions);
        let group_button = |icon: &str, tooltip: String| {
            let button = gtk::Button::builder()
                .icon_name(icon)
                .tooltip_text(&tooltip)
                .valign(gtk::Align::Center)
                .visible(actions)
                .css_classes(["flat"])
                .build();
            button.update_property(&[gtk::accessible::Property::Label(&tooltip)]);
            button
        };
        let schema = init.info.schema.clone();
        let (new_table_label, csv_label) = match schema.as_deref() {
            Some(schema) => (
                crate::tr!("New Table in {schema}\u{2026}").replace("{schema}", schema),
                crate::tr!("Table from CSV in {schema}\u{2026}").replace("{schema}", schema),
            ),
            None => (crate::tr!("New Table\u{2026}"), crate::tr!("Table from CSV\u{2026}")),
        };
        let collapsed = init.group.as_ref().is_some_and(|group| group.collapsed);
        let chevron = gtk::Image::from_icon_name(chevron_icon(collapsed));
        chevron.set_visible(init.group.is_some());
        open_button.set_visible(init.group.is_none());
        Self {
            info: init.info,
            kind: init.kind,
            depth: init.depth,
            group: init.group,
            row: None,
            chevron,
            new_table_button: group_button("list-add-symbolic", new_table_label),
            csv_button: group_button("document-open-symbolic", csv_label),
            open_button,
            popover: None,
        }
    }

    fn shutdown(&mut self, _widgets: &mut Self::Widgets, _output: relm4::Sender<Self::Output>) {
        // Eagerly-parented popovers must be unparented before the
        // row is finalized — GTK warns about leftover children
        // otherwise. shutdown() runs on factory removal (sidebar
        // rebuild, disconnect, search filter), the natural hook.
        if let Some(popover) = self.popover.take() {
            popover.popdown();
            popover.unparent();
        }
    }

    fn init_widgets(
        &mut self,
        _index: &DynamicIndex,
        root: Self::Root,
        _returned_widget: &<Self::ParentWidget as relm4::factory::FactoryView>::ReturnedWidget,
        sender: FactorySender<Self>,
    ) -> Self::Widgets {
        let widgets = view_output!();
        if self.group.is_some() {
            self.describe_group(&root);
            self.wire_group_buttons(&sender);
            return widgets;
        }
        let sender_for_open_button = sender.clone();
        self.open_button
            .connect_clicked(move |_| sender_for_open_button.input(SidebarRowMsg::Open));

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
        if self.kind == SidebarObjectKind::Table {
            let structure_section = gtk::gio::Menu::new();
            structure_section.append(Some(&crate::tr!("Edit Structure")), Some("sidebar-row.edit-structure"));
            structure_section.append(
                Some(&crate::tr!("Show CREATE TABLE")),
                Some("sidebar-row.show-create-table"),
            );
            menu.append_section(None, &structure_section);
            let mutate_section = gtk::gio::Menu::new();
            mutate_section.append(Some(&crate::tr!("Import CSV\u{2026}")), Some("sidebar-row.import-csv"));
            mutate_section.append(Some(&crate::tr!("Drop Table\u{2026}")), Some("sidebar-row.drop-table"));
            menu.append_section(None, &mutate_section);
        }

        let popover = gtk::PopoverMenu::from_model(Some(&menu));
        popover.set_has_arrow(true);
        popover.set_parent(&root);
        // Stash on the model so `shutdown` can unparent it before
        // the row is finalized.
        self.popover = Some(popover.clone());

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
        let sender_show = sender.clone();
        let show_create_action = gtk::gio::ActionEntry::builder("show-create-table")
            .activate(move |_, _, _| sender_show.input(SidebarRowMsg::ShowCreateTable))
            .build();
        let sender_drop = sender.clone();
        let sender_import = sender.clone();
        let import_action = gtk::gio::ActionEntry::builder("import-csv")
            .activate(move |_, _, _| sender_import.input(SidebarRowMsg::ImportCsv))
            .build();
        let drop_action = gtk::gio::ActionEntry::builder("drop-table")
            .activate(move |_, _, _| sender_drop.input(SidebarRowMsg::DropTable))
            .build();
        group.add_action_entries([open_action, edit_action, show_create_action, import_action, drop_action]);
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
            .trigger(&crate::ui::shortcut::parse("Menu"))
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
        let (schema, name) = (self.info.schema.clone(), self.info.name.clone());
        let output = match msg {
            SidebarRowMsg::SetCollapsed(collapsed) => return self.apply_collapse(collapsed),
            SidebarRowMsg::Open => SidebarRowOutput::Open { schema, name },
            SidebarRowMsg::OpenInNewTab => SidebarRowOutput::OpenInNewTab { schema, name },
            SidebarRowMsg::EditStructure => SidebarRowOutput::EditStructure { schema, name },
            SidebarRowMsg::ShowCreateTable => SidebarRowOutput::ShowCreateTable { schema, name },
            SidebarRowMsg::ImportCsv => SidebarRowOutput::ImportCsv { schema, name },
            SidebarRowMsg::DropTable => SidebarRowOutput::DropTable { schema, name },
            SidebarRowMsg::NewTable => SidebarRowOutput::NewTable { schema },
            SidebarRowMsg::TableFromCsv => SidebarRowOutput::TableFromCsv { schema },
        };
        let _ = sender.output(output);
    }
}

impl SidebarRow {
    fn apply_collapse(&self, collapsed: bool) {
        self.chevron.set_icon_name(Some(chevron_icon(collapsed)));
        if let Some(row) = &self.row {
            row.update_state(&[gtk::accessible::State::Expanded(Some(!collapsed))]);
        }
    }

    fn describe_group(&mut self, root: &gtk::ListBoxRow) {
        let Some(group) = &self.group else {
            return;
        };
        root.update_property(&[
            gtk::accessible::Property::Label(&group.label),
            gtk::accessible::Property::Description(&group.count.to_string()),
        ]);
        root.update_state(&[gtk::accessible::State::Expanded(Some(!group.collapsed))]);
        self.row = Some(root.clone());
    }

    fn title(&self) -> String {
        match &self.group {
            Some(group) => group.label.clone(),
            None => self.info.name.clone(),
        }
    }

    fn wire_group_buttons(&self, sender: &FactorySender<Self>) {
        let new_table = sender.clone();
        self.new_table_button
            .connect_clicked(move |_| new_table.input(SidebarRowMsg::NewTable));
        let from_csv = sender.clone();
        self.csv_button
            .connect_clicked(move |_| from_csv.input(SidebarRowMsg::TableFromCsv));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use relm4::factory::FactoryVecDeque;

    fn pump() {
        let context = glib::MainContext::default();
        while context.iteration(false) {}
    }

    #[test]
    #[ignore = "requires an isolated GTK display"]
    fn a_group_row_shows_a_chevron_that_follows_its_collapse_state() {
        relm4::adw::init().unwrap();
        let list = gtk::ListBox::new();
        let mut factory = FactoryVecDeque::<SidebarRow>::builder().launch(list.clone()).detach();
        factory.guard().push_back(SidebarRowInit {
            info: TableInfo {
                schema: None,
                name: "schema:/tables".into(),
            },
            kind: SidebarObjectKind::Group,
            depth: 0,
            group: Some(GroupInit {
                label: "Tables".into(),
                count: 3,
                collapsed: false,
                actions: true,
            }),
        });
        factory.guard().push_back(SidebarRowInit {
            info: TableInfo {
                schema: None,
                name: "users".into(),
            },
            kind: SidebarObjectKind::Table,
            depth: 1,
            group: None,
        });
        pump();
        let chevron_of = |index: i32| {
            let row = list.row_at_index(index).unwrap();
            let body = row.child().unwrap();
            let chevron = body.first_child().unwrap().downcast::<gtk::Image>().unwrap();
            (chevron.icon_name().map(|name| name.to_string()), chevron.is_visible())
        };
        assert_eq!(chevron_of(0), (Some("pan-down-symbolic".into()), true));
        assert!(!chevron_of(1).1, "an object row has no chevron");

        factory.send(0, SidebarRowMsg::SetCollapsed(true));
        pump();

        assert_eq!(chevron_of(0).0.as_deref(), Some("pan-end-symbolic"));
    }
}
