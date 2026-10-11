use std::cell::RefCell;
use std::collections::HashSet;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::factory::FactoryVecDeque;
use relm4::prelude::*;
use relm4::{adw, gtk};

use super::{App, AppMsg, AppWidgets, OpenMode};
use crate::services::sidebar_tree::{CollapseState, NodeKind, TreeNode, visible_nodes};
use crate::ui::sidebar_row::{SidebarRow, SidebarRowOutput};

pub(super) struct SidebarParts {
    pub(super) factory: FactoryVecDeque<SidebarRow>,
    pub(super) nodes: Rc<RefCell<Vec<TreeNode>>>,
    pub(super) collapsed: Rc<RefCell<CollapseState>>,
    pub(super) visible: Rc<RefCell<HashSet<usize>>>,
}

pub(super) fn refresh_visible(
    nodes: &RefCell<Vec<TreeNode>>,
    collapsed: &RefCell<CollapseState>,
    visible: &RefCell<HashSet<usize>>,
    query: &str,
) {
    let shown = visible_nodes(&nodes.borrow(), &collapsed.borrow(), query);
    *visible.borrow_mut() = shown.into_iter().collect();
}

pub(super) fn build_sidebar(widgets: &AppWidgets, sender: &ComponentSender<App>) -> SidebarParts {
    let sidebar_nodes: Rc<RefCell<Vec<TreeNode>>> = Rc::new(RefCell::new(Vec::new()));
    let sidebar_collapsed: Rc<RefCell<CollapseState>> = Rc::new(RefCell::new(CollapseState::default()));
    let sidebar_visible: Rc<RefCell<HashSet<usize>>> = Rc::new(RefCell::new(HashSet::new()));

    let sidebar_factory: FactoryVecDeque<SidebarRow> = FactoryVecDeque::builder()
        .launch(
            gtk::ListBox::builder()
                .selection_mode(gtk::SelectionMode::Single)
                .activate_on_single_click(true)
                .css_classes(["navigation-sidebar"])
                .build(),
        )
        .forward(sender.input_sender(), |out| match out {
            SidebarRowOutput::Open { schema, name } => AppMsg::SelectTable {
                schema,
                name,
                open_mode: OpenMode::SwitchOrAppend,
            },
            // Plain click + Enter activation route through the parent
            // ListBox's `row-activated` signal (wired below), which is
            // the only signal that fires for both mouse and keyboard.
            // The factory only carries the Ctrl+click / right-click
            // "open in new tab" path.
            SidebarRowOutput::OpenInNewTab { schema, name } => AppMsg::SelectTable {
                schema,
                name,
                open_mode: OpenMode::NewTab,
            },
            SidebarRowOutput::EditStructure { schema, name } => AppMsg::EditStructureTab { schema, table: name },
            SidebarRowOutput::ShowCreateTable { schema, name } => {
                AppMsg::ShowCreateTableForExisting { schema, table: name }
            }
            SidebarRowOutput::ImportCsv { schema, name } => AppMsg::ImportCsvIntoTable { schema, table: name },
            SidebarRowOutput::DropTable { schema, name } => AppMsg::DropTablePrompt { schema, table: name },
            SidebarRowOutput::NewTable { schema } => AppMsg::NewTableTab { schema },
            SidebarRowOutput::TableFromCsv { schema } => AppMsg::CreateTableFromCsv { schema },
        });

    let sidebar_listbox = sidebar_factory.widget();
    widgets.sidebar_scroll.set_child(Some(sidebar_listbox));

    // Plain click + Enter on focused row → SwitchOrAppend. This is
    // the single source of truth for sidebar activation; per-row
    // keybinding signals (gtk::ListBoxRow::activate) only fire on
    // Enter and would miss mouse clicks.
    let nodes_for_activate = sidebar_nodes.clone();
    let activate_sender = sender.clone();
    sidebar_listbox.connect_row_activated(move |_, row| {
        let nodes = nodes_for_activate.borrow();
        let Some(node) = nodes.get(row.index() as usize) else {
            return;
        };
        match &node.kind {
            NodeKind::Table { schema, name } | NodeKind::View { schema, name } => {
                activate_sender.input(AppMsg::SelectTable {
                    schema: schema.clone(),
                    name: name.clone(),
                    open_mode: OpenMode::SwitchOrAppend,
                });
            }
            NodeKind::Schema | NodeKind::Group(_) => {
                activate_sender.input(AppMsg::ToggleSidebarGroup(node.key.clone()));
            }
        }
    });

    let visible_for_filter = sidebar_visible.clone();
    sidebar_listbox.set_filter_func(move |row| visible_for_filter.borrow().contains(&(row.index() as usize)));
    let listbox_for_invalidate = sidebar_listbox.clone();
    let (nodes_for_search, collapsed_for_search, visible_for_search) = (
        sidebar_nodes.clone(),
        sidebar_collapsed.clone(),
        sidebar_visible.clone(),
    );
    let search_entry = widgets.table_search.clone();
    widgets.table_search.connect_search_changed(move |_| {
        refresh_visible(
            &nodes_for_search,
            &collapsed_for_search,
            &visible_for_search,
            &search_entry.text(),
        );
        listbox_for_invalidate.invalidate_filter();
    });
    widgets.table_search_bar.connect_entry(&widgets.table_search);
    widgets
        .table_search_bar
        .set_key_capture_widget(Some(&widgets.sidebar_root));

    // Empty-state placeholder. Shown by GtkListBox when no row is
    // visible — covers both "the database has zero tables" and
    // "the search filtered everything out". Without this, the
    // sidebar renders as a blank surface and reads as broken.
    // AdwStatusPage `.compact` is the documented empty-state
    // widget for narrow containers (matches GNOME Files's
    // sidebar-empty look).
    let sidebar_placeholder = adw::StatusPage::builder()
        .icon_name("view-list-symbolic")
        .title(crate::tr!("No tables"))
        .description(crate::tr!(
            "Nothing matches the current search, or this connection has no tables yet."
        ))
        .build();
    sidebar_placeholder.add_css_class("compact");
    sidebar_listbox.set_placeholder(Some(&sidebar_placeholder));

    // Two-way bind the sidebar header's search toggle to the SearchBar.
    // Click toggle → SearchBar reveals + entry focuses; press Esc →
    // SearchBar hides → toggle deactivates.
    widgets
        .table_search_toggle
        .bind_property("active", &widgets.table_search_bar, "search-mode-enabled")
        .bidirectional()
        .sync_create()
        .build();

    SidebarParts {
        factory: sidebar_factory,
        nodes: sidebar_nodes,
        collapsed: sidebar_collapsed,
        visible: sidebar_visible,
    }
}
