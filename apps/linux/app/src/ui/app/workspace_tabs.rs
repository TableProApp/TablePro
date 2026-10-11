use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::{gio, glib};
use relm4::{Component, ComponentController, ComponentSender, adw, gtk};

use uuid::Uuid;

use crate::services::workspace_state;
use crate::ui::browse_tab::{BrowseTab, BrowseTabInit, BrowseTabInput, BrowseTabOutput};
use crate::ui::editor::{SqlEditor, SqlEditorInit, SqlEditorInput, SqlEditorOutput, derive_tab_label};

use super::types::{CLOSED_TABS_CAPACITY, read_workspace_tab_id, write_workspace_tab_id};
use super::{App, AppMsg, ClosedTabDescriptor, EditorTabSlot, OpenMode, WorkspaceTab};

impl App {
    /// Builds the unified AdwTabOverview tree once per connection.
    /// Idempotent via `workspace_root_added`.
    pub(super) fn ensure_workspace_root(&mut self, sender: ComponentSender<Self>) {
        if self.workspace_root_added.get() {
            return;
        }
        if self.workspace_root.is_none() {
            self.build_workspace_root(sender);
        }
        if let Some(root) = self.workspace_root.as_ref()
            && self.workspace_outer_stack.child_by_name("tabs").is_none()
        {
            self.workspace_outer_stack.add_named(root, Some("tabs"));
        }
        self.workspace_root_added.set(true);
    }

    fn build_workspace_root(&mut self, sender: ComponentSender<Self>) {
        let tab_view = adw::TabView::new();
        tab_view.set_shortcuts(adw::TabViewShortcuts::all() - adw::TabViewShortcuts::CONTROL_TAB);
        let tab_bar = adw::TabBar::builder()
            .view(&tab_view)
            .autohide(false)
            .expand_tabs(true)
            .build();

        let overview_button = adw::TabButton::builder()
            .view(&tab_view)
            .action_name("overview.open")
            .tooltip_text(crate::tr!("View open tabs"))
            .valign(gtk::Align::Center)
            .build();
        // Hide the overview button until there are at least 2 tabs —
        // its grid is meaningless when there's only one page open.
        // Bound via property-binding so it tracks `n-pages` live.
        overview_button.set_visible(tab_view.n_pages() > 1);
        let overview_button_for_pages = overview_button.clone();
        tab_view.connect_n_pages_notify(move |view| {
            overview_button_for_pages.set_visible(view.n_pages() > 1);
        });
        tab_bar.set_start_action_widget(Some(&overview_button));

        // "+" button in the tab bar opens a new editor (query) tab —
        // this is the only way to create an editor tab from the UI.
        // Browse tabs come from sidebar clicks.
        let new_query_button = gtk::Button::builder()
            .icon_name("tab-new-symbolic")
            .tooltip_text(crate::tr!("New query (Ctrl+E)"))
            .valign(gtk::Align::Center)
            .build();
        new_query_button.add_css_class("flat");
        let new_tab_sender = sender.clone();
        new_query_button.connect_clicked(move |_| new_tab_sender.input(AppMsg::NewEditorTab));
        tab_bar.set_end_action_widget(Some(&new_query_button));

        // 2-step close: TabView signals close → App message → close_finish.
        let close_sender = sender.clone();
        tab_view.connect_close_page(move |_view, page| {
            if let Some(id) = read_workspace_tab_id(page) {
                close_sender.input(AppMsg::WorkspaceTabClosed(id));
            }
            glib::Propagation::Stop
        });

        // Right-click tab → context menu. AdwTabView reads a menu model
        // and fires `connect_setup_menu` with the target page just
        // before the popover opens; we stash that page in a shared
        // Cell so the action callbacks know which tab the user
        // right-clicked. Setting `menu-model` on AdwTabView is the
        // documented way to extend the per-tab popover.
        let menu_target: Rc<RefCell<Option<adw::TabPage>>> = Rc::new(RefCell::new(None));
        let menu_target_setup = menu_target.clone();
        tab_view.connect_setup_menu(move |_view, page| {
            *menu_target_setup.borrow_mut() = page.cloned();
        });
        let action_group = gio::SimpleActionGroup::new();
        let close_others_action = gio::SimpleAction::new("close-others", None);
        let menu_target_others = menu_target.clone();
        let sender_close_others = sender.clone();
        close_others_action.connect_activate(move |_, _| {
            let target = menu_target_others.borrow().clone();
            if let Some(page) = target
                && let Some(id) = read_workspace_tab_id(&page)
            {
                sender_close_others.input(AppMsg::CloseOtherWorkspaceTabs(id));
            }
        });
        action_group.add_action(&close_others_action);
        let close_right_action = gio::SimpleAction::new("close-right", None);
        let menu_target_right = menu_target;
        let sender_close_right = sender.clone();
        close_right_action.connect_activate(move |_, _| {
            let target = menu_target_right.borrow().clone();
            if let Some(page) = target
                && let Some(id) = read_workspace_tab_id(&page)
            {
                sender_close_right.input(AppMsg::CloseWorkspaceTabsToRight(id));
            }
        });
        action_group.add_action(&close_right_action);
        tab_view.insert_action_group("tab", Some(&action_group));

        let bulk_menu = gio::Menu::new();
        bulk_menu.append(Some(&crate::tr!("Close Other Tabs")), Some("tab.close-others"));
        bulk_menu.append(Some(&crate::tr!("Close Tabs to the Right")), Some("tab.close-right"));
        tab_view.set_menu_model(Some(&bulk_menu));

        // Both selection-change AND any pages-list change (insert /
        // remove / drag-reorder) trigger persist + title-refresh.
        // Without connect_pages_notify, drag-reorder doesn't persist
        // until the next other event.
        let pages_sender = sender.clone();
        tab_view.connect_selected_page_notify(move |_| {
            pages_sender.input(AppMsg::WorkspaceTabsChanged);
        });
        let reorder_sender = sender.clone();
        tab_view.connect_pages_notify(move |_| {
            reorder_sender.input(AppMsg::WorkspaceTabsChanged);
        });

        let inner = gtk::Box::builder().orientation(gtk::Orientation::Vertical).build();
        inner.append(&tab_bar);
        inner.append(&tab_view);

        let tab_overview = adw::TabOverview::builder()
            .view(&tab_view)
            .enable_new_tab(true) // overview "+" → editor tab
            .enable_search(true)
            .child(&inner)
            .build();
        // Overview "+" button must return a real TabPage synchronously —
        // we build an SqlEditor inline, register the slot, and return
        // the page. Browse tabs aren't creatable from the overview
        // (they need a sidebar table target).
        // Overview "+" must return a real TabPage synchronously. We
        // construct an editor slot inline using the same label scheme
        // as `append_editor_tab` ("Query 1", "Query 2", …) so the two
        // entry points are visually indistinguishable.
        let workspace_tabs_for_create = self.workspace_tabs.clone();
        let tab_view_for_create = tab_view.clone();
        let schema_buffer_for_create = self.schema_buffer.clone();
        let schema_index_for_create = self.schema_index.clone();
        let history_for_create = self.history.clone();
        let database_for_create = self.database.clone();
        let preferences_for_create = self.preferences.clone();
        let sender_for_create = sender.clone();
        // The workspace root is rebuilt on every connect, so the identifier
        // captured here always belongs to the connection this window owns.
        let connection_id_for_create = self.connection_id;
        tab_overview.connect_create_tab(move |_| {
            let tab_id = Uuid::new_v4();
            let editor = SqlEditor::builder()
                .launch(SqlEditorInit {
                    connection_id: connection_id_for_create,
                    schema_buffer: schema_buffer_for_create.clone(),
                    schema_index: schema_index_for_create.clone(),
                    initial_query: None,
                    history: history_for_create.clone(),
                    database: database_for_create.clone(),
                    preferences: preferences_for_create.clone(),
                })
                .forward(sender_for_create.input_sender(), move |out| match out {
                    SqlEditorOutput::CatalogChanged(origin) => AppMsg::SchemaChanged {
                        origin,
                        schema: None,
                        table: None,
                    },
                    SqlEditorOutput::RunStateChanged(running) => AppMsg::EditorTabRunStateChanged(tab_id, running),
                    SqlEditorOutput::QueryChanged(text) => AppMsg::EditorTabQueryChanged(tab_id, text),
                    SqlEditorOutput::NeedColumns(tables) => AppMsg::EditorNeedsColumns(tables),
                    SqlEditorOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                    SqlEditorOutput::ShowRowAsJson(body) => AppMsg::ShowAlert {
                        title: crate::tr!("Row as JSON"),
                        body,
                    },
                    SqlEditorOutput::ExportResults { result, name } => AppMsg::ExportResults { result, name },
                });
            let page = tab_view_for_create.append(editor.widget());
            let editor_count = workspace_tabs_for_create
                .borrow()
                .values()
                .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
                .count();
            let label = default_editor_tab_label(editor_count + 1);
            page.set_title(&label);
            // Empty query → no tooltip; tooltip will be set on first edit
            // via on_editor_tab_query_changed.
            write_workspace_tab_id(&page, tab_id);
            let slot = EditorTabSlot {
                controller: editor,
                page: page.clone(),
                query: String::new(),
                running: false,
                file: None,
            };
            {
                let mut tabs = workspace_tabs_for_create.borrow_mut();
                tabs.insert(tab_id, WorkspaceTab::Editor(slot));
            }
            sender_for_create.input(AppMsg::WorkspaceTabsChanged);
            page
        });

        // Ctrl+T is bound globally (alongside Ctrl+E) in
        // `install_window_shortcuts` so it fires even when this
        // tab-area widget tree isn't focused (e.g. the empty-state
        // status page). Keeping a local controller here would just
        // duplicate the binding.
        let _ = sender;

        self.workspace_root = Some(tab_overview);
        self.workspace_tab_view = Some(tab_view);
        self.apply_connection_strip();
    }

    /// Restore workspace tabs from disk for the just-connected database.
    pub(super) fn restore_workspace_tabs(&mut self, connection_id: Uuid, sender: ComponentSender<Self>) {
        let Some(saved) = self.workspace.load_connection(connection_id) else {
            self.workspace_outer_stack.set_visible_child_name("empty");
            return;
        };
        if saved.tabs.is_empty() {
            self.workspace_outer_stack.set_visible_child_name("empty");
            return;
        }
        for record in &saved.tabs {
            match workspace_state::restored_workspace_tab(record) {
                Some(workspace_state::RestoredWorkspaceTab::Editor { query, draft_id, file }) => {
                    self.append_editor_draft(Some(query), draft_id, sender.clone());
                    if let (Some(path), Some(tab)) = (file, self.selected_editor_tab_id()) {
                        self.restore_editor_file(tab, path, sender.clone());
                    }
                }
                Some(workspace_state::RestoredWorkspaceTab::Table {
                    schema,
                    table,
                    offset,
                    page_size,
                    sort,
                }) => {
                    self.append_table_tab(schema, table, offset, page_size, sort, sender.clone());
                }
                Some(workspace_state::RestoredWorkspaceTab::Structure { schema, table }) => {
                    self.append_existing_structure_tab(schema, table, sender.clone());
                }
                None => {}
            }
        }
        if let Some(tab_view) = self.workspace_tab_view.as_ref()
            && let Some(page) = tab_view.pages().item(saved.active_idx).and_downcast::<adw::TabPage>()
        {
            tab_view.set_selected_page(&page);
        }
        self.workspace_outer_stack.set_visible_child_name("tabs");
    }

    /// Public entry: append a Structure draft tab for the New-Table
    /// flow. Edit-mode is no longer reachable through this helper;
    /// use `append_table_tab` for the unified Browse + Structure
    /// view of an existing table.
    pub(super) fn append_new_structure_tab(&mut self, schema: Option<String>, sender: ComponentSender<Self>) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let driver_id = self.driver_id().to_string();
        let init = crate::ui::structure_tab::StructureTabInit {
            tab_id,
            schema: schema.clone(),
            table: String::new(),
            mode: crate::ui::structure_tab::StructureMode::New,
            driver_id,
            // New mode has nothing to introspect (no real table yet).
            defer_initial_fetch: false,
        };
        let controller =
            crate::ui::structure_tab::StructureTab::builder()
                .launch(init)
                .forward(sender.input_sender(), move |out| match out {
                    crate::ui::structure_tab::StructureTabOutput::DirtyChanged(dirty) => {
                        AppMsg::StructureTabDirtyChanged(tab_id, dirty)
                    }
                    crate::ui::structure_tab::StructureTabOutput::FetchStructure => {
                        AppMsg::FetchStructureData { tab_id }
                    }
                    crate::ui::structure_tab::StructureTabOutput::ExecuteTransaction { statements } => {
                        AppMsg::ExecuteStructureTransaction { tab_id, statements }
                    }
                    crate::ui::structure_tab::StructureTabOutput::DropTableRequested { schema, table } => {
                        AppMsg::DropTablePrompt { schema, table }
                    }
                    crate::ui::structure_tab::StructureTabOutput::ShowToast(msg) => AppMsg::ShowToast(msg),
                    crate::ui::structure_tab::StructureTabOutput::ShowAlert { title, body } => {
                        AppMsg::ShowAlert { title, body }
                    }
                });

        let page = tab_view.append(controller.widget());
        page.set_title(&crate::tr!("New Table"));
        write_workspace_tab_id(&page, tab_id);

        let slot = super::StructureTabSlot {
            id: tab_id,
            controller,
            page: page.clone(),
            schema,
            table: String::new(),
            mode: crate::ui::structure_tab::StructureMode::New,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Structure(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
    }

    /// Public entry: append a unified Table tab (Browse + Structure
    /// share one AdwTabPage with an `AdwViewSwitcher` toggle). Both
    /// sub-controllers initialise eagerly so switching modes is
    /// instant and per-side state (pagination, sort, search,
    /// pending edits) survives a round trip.
    /// Append a Browse (Data-view) tab for an existing
    /// `(schema, table)`. The DDL editor for the same table opens as
    /// a separate `WorkspaceTab::Structure` page via the sidebar
    /// right-click "Edit Structure" action (`append_existing_structure_tab`).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn append_table_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
        sender: ComponentSender<Self>,
    ) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let driver_id = self.driver_id().to_string();
        let connection_id = self.connection_id;
        let read_only = self.read_only;

        let browse_init = BrowseTabInit {
            tab_id,
            schema: schema.clone(),
            table: table.clone(),
            driver_id,
            connection_id,
            read_only,
            page_size,
            initial_offset: offset,
            initial_sort: sort,
            persistence: self.persistence.clone(),
            database: self.database.clone(),
        };
        let browse = BrowseTab::builder()
            .launch(browse_init)
            .forward(sender.input_sender(), move |out| match out {
                BrowseTabOutput::FetchPage => AppMsg::FetchBrowsePage(tab_id),
                BrowseTabOutput::FetchColumns => AppMsg::FetchBrowseColumns(tab_id),
                BrowseTabOutput::FetchRowCount => AppMsg::FetchBrowseRowCount(tab_id),
                BrowseTabOutput::FetchCellValue {
                    request,
                    col_index,
                    column_name,
                    row_key,
                } => AppMsg::FetchBrowseCellValue(tab_id, request, col_index, column_name, row_key),
                BrowseTabOutput::StateChanged => AppMsg::WorkspaceTabsChanged,
                BrowseTabOutput::CopyRowAsInsert { row_position } => AppMsg::CopyRowAsInsert { tab_id, row_position },
                BrowseTabOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                BrowseTabOutput::ShowRowAsJson(body) => AppMsg::ShowAlert {
                    title: crate::tr!("Row as JSON"),
                    body,
                },
                BrowseTabOutput::ExportResults { result, name } => AppMsg::ExportResults { result, name },
                BrowseTabOutput::SchemaWordsChanged(_words) => AppMsg::WorkspaceSchemaWordsChanged,
                BrowseTabOutput::ShowSelectionAlert { title, body } => AppMsg::ShowAlert { title, body },
                BrowseTabOutput::ShowToast(msg) => AppMsg::ShowToast(msg),
                BrowseTabOutput::DirtyChanged(dirty) => AppMsg::BrowseTabDirtyChanged(tab_id, dirty),
                BrowseTabOutput::ExecuteTransaction { statements, sources } => AppMsg::ExecuteBrowseTransaction {
                    tab_id,
                    statements,
                    sources,
                },
            });

        let page = tab_view.append(browse.widget());
        let label = qualified_browse_tab_label(self.sidebar_schemas_distinct(), schema.as_deref(), &table);
        page.set_title(&label);
        if let Some(tip) = browse_tab_tooltip(schema.as_deref(), &table, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        let slot = super::TableTabSlot {
            id: tab_id,
            page: page.clone(),
            schema,
            table,
            browse,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Table(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
    }

    /// Open a Structure (DDL editor) tab for an EXISTING
    /// `(schema, table)`. Mirrors `append_new_structure_tab` shape
    /// but uses `StructureMode::Edit` and fetches the table's columns
    /// / indexes / FKs immediately. Called from
    /// `on_edit_structure_tab` (sidebar right-click → Edit Structure).
    pub(super) fn append_existing_structure_tab(
        &mut self,
        schema: Option<String>,
        table: String,
        sender: ComponentSender<Self>,
    ) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = Uuid::new_v4();
        let driver_id = self.driver_id().to_string();
        let mode = crate::ui::structure_tab::StructureMode::Edit;
        let init = crate::ui::structure_tab::StructureTabInit {
            tab_id,
            schema: schema.clone(),
            table: table.clone(),
            mode,
            driver_id,
            defer_initial_fetch: false,
        };
        let controller =
            crate::ui::structure_tab::StructureTab::builder()
                .launch(init)
                .forward(sender.input_sender(), move |out| match out {
                    crate::ui::structure_tab::StructureTabOutput::DirtyChanged(dirty) => {
                        AppMsg::StructureTabDirtyChanged(tab_id, dirty)
                    }
                    crate::ui::structure_tab::StructureTabOutput::FetchStructure => {
                        AppMsg::FetchStructureData { tab_id }
                    }
                    crate::ui::structure_tab::StructureTabOutput::ExecuteTransaction { statements } => {
                        AppMsg::ExecuteStructureTransaction { tab_id, statements }
                    }
                    crate::ui::structure_tab::StructureTabOutput::DropTableRequested { schema, table } => {
                        AppMsg::DropTablePrompt { schema, table }
                    }
                    crate::ui::structure_tab::StructureTabOutput::ShowToast(msg) => AppMsg::ShowToast(msg),
                    crate::ui::structure_tab::StructureTabOutput::ShowAlert { title, body } => {
                        AppMsg::ShowAlert { title, body }
                    }
                });

        let page = tab_view.append(controller.widget());
        let title = qualified_browse_tab_label(self.sidebar_schemas_distinct(), schema.as_deref(), &table);
        // Disambiguate from the Data-side tab with the same base name
        // by suffixing the structure tab title — "products · Structure".
        // GNOME uses U+00B7 middle dot as the canonical separator
        // (Files, Builder, Console all do this for compound titles).
        page.set_title(&format!("{title} · {}", crate::tr!("Structure")));
        write_workspace_tab_id(&page, tab_id);

        let slot = super::StructureTabSlot {
            id: tab_id,
            controller,
            page: page.clone(),
            schema,
            table,
            mode,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Structure(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.persist_workspace_state();
    }

    /// Public entry: append an Editor tab with optional initial query.
    pub(super) fn append_editor_tab(&mut self, initial_query: Option<String>, sender: ComponentSender<Self>) {
        self.append_editor_draft(initial_query, None, sender);
    }

    fn append_editor_draft(
        &mut self,
        initial_query: Option<String>,
        draft_id: Option<Uuid>,
        sender: ComponentSender<Self>,
    ) {
        self.ensure_workspace_root(sender.clone());
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        let tab_id = draft_id.unwrap_or_else(Uuid::new_v4);
        let query = initial_query.clone().unwrap_or_default();
        let editor = SqlEditor::builder()
            .launch(SqlEditorInit {
                connection_id: self.connection_id,
                schema_buffer: self.schema_buffer.clone(),
                schema_index: self.schema_index.clone(),
                initial_query,
                history: self.history.clone(),
                database: self.database.clone(),
                preferences: self.preferences.clone(),
            })
            .forward(sender.input_sender(), move |out| match out {
                SqlEditorOutput::CatalogChanged(origin) => AppMsg::SchemaChanged {
                    origin,
                    schema: None,
                    table: None,
                },
                SqlEditorOutput::RunStateChanged(running) => AppMsg::EditorTabRunStateChanged(tab_id, running),
                SqlEditorOutput::QueryChanged(text) => AppMsg::EditorTabQueryChanged(tab_id, text),
                SqlEditorOutput::NeedColumns(tables) => AppMsg::EditorNeedsColumns(tables),
                SqlEditorOutput::CopyToClipboard(text) => AppMsg::CopyToClipboard(text),
                SqlEditorOutput::ShowRowAsJson(body) => AppMsg::ShowAlert {
                    title: crate::tr!("Row as JSON"),
                    body,
                },
                SqlEditorOutput::ExportResults { result, name } => AppMsg::ExportResults { result, name },
            });
        let page = tab_view.append(editor.widget());
        let label = match query.trim().is_empty() {
            true => default_editor_tab_label(self.editor_tab_count() + 1),
            false => derive_tab_label(&query),
        };
        page.set_title(&label);
        if let Some(tip) = editor_tab_tooltip(&query, &label) {
            page.set_tooltip(&tip);
        }
        write_workspace_tab_id(&page, tab_id);

        let slot = EditorTabSlot {
            controller: editor,
            page: page.clone(),
            query,
            running: false,
            file: None,
        };
        self.workspace_tabs
            .borrow_mut()
            .insert(tab_id, WorkspaceTab::Editor(slot));
        tab_view.set_selected_page(&page);
        self.workspace_outer_stack.set_visible_child_name("tabs");
        self.refresh_window_title();
        self.rebuild_schema_buffer();
        self.persist_workspace_state();
    }

    pub(super) fn close_workspace_tab_by_id(&mut self, id: Uuid, sender: ComponentSender<Self>) {
        let Some(tab_view) = self.workspace_tab_view.clone() else {
            return;
        };
        // If this is a Browse tab with pending changeset, intercept the
        // close with an AdwAlertDialog (Discard / Cancel). The user can
        // also cancel close, save manually, then close — no Save-and-
        // close branch keeps the async commit logic out of this path.
        let pending = self
            .workspace_tabs
            .borrow()
            .get(&id)
            .and_then(|t| match t {
                WorkspaceTab::Structure(s) => {
                    crate::services::structure_tracker::with_tab_ref(s.id, |tr| tr.has_pending())
                }
                WorkspaceTab::Table(s) => {
                    let data_dirty =
                        crate::services::change_tracker::with_tab_ref(s.id, |tr| tr.has_pending()).unwrap_or(false);
                    let struct_dirty =
                        crate::services::structure_tracker::with_tab_ref(s.id, |tr| tr.has_pending()).unwrap_or(false);
                    Some(data_dirty || struct_dirty)
                }
                WorkspaceTab::Editor(s) => Some(s.has_unsaved_file_changes()),
            })
            .unwrap_or(false);
        if pending {
            let page = self.workspace_tabs.borrow().get(&id).map(|t| match t {
                WorkspaceTab::Editor(s) => s.page.clone(),
                WorkspaceTab::Structure(s) => s.page.clone(),
                WorkspaceTab::Table(s) => s.page.clone(),
            });
            let Some(page) = page else { return };
            // Tab title without the dirty bullet — the heading reads
            // as the natural-language name of the tab (`categories`),
            // not `• categories`. Strip a leading "• " if present.
            let raw_title = page.title().to_string();
            let tab_label = raw_title.strip_prefix("• ").unwrap_or(&raw_title).to_string();
            // Cancel | Discard(destructive) | Save(suggested), Save is
            // default. Mirrors GNOME Text Editor's close-with-unsaved
            // template (libadwaita AdwAlertDialog reference). Naming
            // the tab in the heading + factual body copy follows the
            // GNOME HIG pattern for destructive-confirmation dialogs.
            let dialog = adw::AlertDialog::new(None, None);
            dialog.set_heading(Some(
                &crate::tr!("Save changes to “{name}”?").replace("{name}", &tab_label),
            ));
            dialog.set_body(&crate::tr!(
                "Unsaved changes will be permanently lost if you discard them."
            ));
            dialog.add_response("cancel", &crate::tr!("Cancel"));
            dialog.add_response("discard", &crate::tr!("Discard"));
            dialog.add_response("save", &crate::tr!("Save"));
            dialog.set_response_appearance("discard", adw::ResponseAppearance::Destructive);
            dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);
            dialog.set_default_response(Some("save"));
            dialog.set_close_response("cancel");
            let tab_view_for_resp = tab_view.clone();
            let page_for_resp = page.clone();
            let sender_for_resp = sender.clone();
            let close_after_save = self.close_after_save.clone();
            // Snapshot which trackers actually have pending changes
            // before the dialog opens. Drives the discard + save
            // branches so a Table tab whose only dirt is on the
            // Structure side doesn't try to save through the Browse
            // path (and vice versa).
            let data_dirty = crate::services::change_tracker::with_tab_ref(id, |tr| tr.has_pending()).unwrap_or(false);
            let struct_dirty =
                crate::services::structure_tracker::with_tab_ref(id, |tr| tr.has_pending()).unwrap_or(false);
            let file_dirty = matches!(
                self.workspace_tabs.borrow().get(&id),
                Some(WorkspaceTab::Editor(slot)) if slot.has_unsaved_file_changes()
            );
            dialog.connect_response(None, move |dlg, response| {
                dlg.close();
                match response {
                    "discard" => {
                        if data_dirty {
                            crate::services::change_tracker::with_tab(id, |t| t.clear());
                        }
                        if struct_dirty {
                            crate::services::structure_tracker::with_tab(id, |t| t.clear());
                        }
                        sender_for_resp.input(AppMsg::WorkspaceTabClosed(id));
                    }
                    "save" => {
                        // Mark the tab so SaveCompletedForTab will close
                        // it once the transaction commits. The counter
                        // increments once per dispatched save: a Table
                        // tab dirty on both sides bumps to 2, and the
                        // close fires only after BOTH saves drain it.
                        // SaveFailed removes the entry entirely and
                        // aborts the close.
                        let pending_saves: u32 =
                            u32::from(data_dirty) + u32::from(struct_dirty) + u32::from(file_dirty);
                        if pending_saves > 0 {
                            *close_after_save.borrow_mut().entry(id).or_insert(0) += pending_saves;
                        }
                        // Revert AdwTabView's "closing" state for now
                        // (the user might still cancel via SaveFailed).
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                        // Dispatch the right save path per dirty side.
                        if data_dirty {
                            sender_for_resp.input(AppMsg::SaveActiveBrowseTabById(id));
                        }
                        if struct_dirty {
                            sender_for_resp.input(AppMsg::SaveActiveStructureTabById(id));
                        }
                        if file_dirty {
                            sender_for_resp.input(AppMsg::SaveEditorFile {
                                tab: id,
                                overwrite: false,
                            });
                        }
                    }
                    _ => {
                        // Cancel: revert AdwTabView's "closing" state
                        // so the page stays open. Without this the X
                        // click would still dismiss the page.
                        tab_view_for_resp.close_page_finish(&page_for_resp, false);
                    }
                }
            });
            dialog.present(Some(&self.window));
            return;
        }

        if self.confirm_close_with_open_transaction(id, &tab_view, sender.clone()) {
            return;
        }
        self.finish_close_workspace_tab(id, &tab_view, sender);
    }

    /// Tear down a tab without prompting. Internal helper called once
    /// the close-with-pending dialog (if any) has resolved.
    pub(super) fn finish_close_workspace_tab(
        &mut self,
        id: Uuid,
        tab_view: &adw::TabView,
        sender: ComponentSender<Self>,
    ) {
        if matches!(self.workspace_tabs.borrow().get(&id), Some(WorkspaceTab::Editor(_))) {
            if let Some(page) = self.workspace_tabs.borrow().get(&id).map(|tab| match tab {
                WorkspaceTab::Editor(slot) => slot.page.clone(),
                WorkspaceTab::Structure(slot) => slot.page.clone(),
                WorkspaceTab::Table(slot) => slot.page.clone(),
            }) {
                self.recent_pages.borrow_mut().forget(&page);
                tab_view.close_page_finish(&page, false);
            }
            self.close_tab_after_session_cleanup(id, sender);
            return;
        }
        self.finish_close_workspace_tab_now(id, tab_view);
    }

    pub(super) fn finish_close_workspace_tab_now(&mut self, id: Uuid, tab_view: &adw::TabView) {
        let removed = self.workspace_tabs.borrow_mut().remove(&id);
        let Some(removed) = removed else {
            return;
        };
        // Snapshot the closed tab into the reopen stack BEFORE running
        // the per-kind teardown below — the BrowseModel still has its
        // pagination + sort state intact, and the EditorTabSlot still
        // owns the latest query buffer. New-mode Structure drafts are
        // skipped because the table they describe doesn't exist yet,
        // so reopening a draft would be useless.
        if let Some(descriptor) = describe_closed_tab(&removed) {
            push_closed_tab(&self.closed_tabs_stack, descriptor);
        }
        // Drop any close-after-save / window-close-after-save intent
        // pinned to this tab. `close_tabs_for_table` (Drop Table)
        // calls into here directly without going through the per-tab
        // close prompt, so a stale entry would otherwise live on
        // forever and cause a future unrelated SaveCompleted to
        // spuriously close the window.
        self.close_after_save.borrow_mut().remove(&id);
        match &removed {
            WorkspaceTab::Editor(slot) => {
                let _ = slot.controller.sender().send(SqlEditorInput::Cancel);
            }
            WorkspaceTab::Structure(slot) => {
                crate::services::structure_tracker::close_tab(slot.id);
                self.structure_saves_in_flight.borrow_mut().remove(&slot.id);
            }
            WorkspaceTab::Table(slot) => {
                // A Table tab owns BOTH a Browse-side row tracker and a
                // Structure-side DDL tracker against the same uuid; close
                // both registries. Also drop the in-flight-save guard
                // entry so a re-opened tab with the same uuid (or a
                // dropped async future from `drop_on_shutdown`) doesn't
                // leave the save path permanently locked.
                crate::services::change_tracker::close_tab(slot.id);
                crate::services::structure_tracker::close_tab(slot.id);
                self.structure_saves_in_flight.borrow_mut().remove(&slot.id);
            }
        }
        let page = match &removed {
            WorkspaceTab::Editor(s) => s.page.clone(),
            WorkspaceTab::Structure(s) => s.page.clone(),
            WorkspaceTab::Table(s) => s.page.clone(),
        };
        self.recent_pages.borrow_mut().forget(&page);
        self.read_scopes.borrow_mut().cancel_tab(id);
        tab_view.close_page_finish(&page, true);
        drop(removed);
        self.persist_workspace_state();
        if self.workspace_tabs.borrow().is_empty() {
            self.workspace_outer_stack.set_visible_child_name("empty");
        }
        self.rebuild_schema_buffer();
        self.refresh_window_title();
    }

    /// Sidebar-click dispatcher. Two behaviours:
    ///
    /// - `SwitchOrAppend` (plain click): if a Browse tab for
    ///   `(schema, table)` is already open, activate it; otherwise
    ///   append a new Browse tab. Never closes anything — tabs only
    ///   go away when the user clicks the X.
    /// - `NewTab` (Ctrl+click / right-click "Open in new tab"): always
    ///   append a new tab even if the same table is already open.
    ///
    /// The earlier "smart-replace" sub-case (close active + append new
    /// in one step) was dropped because AdwTabView's close-page
    /// animation overlapped with the append, producing a visual flash
    /// where the user briefly saw the closing tab and the new tab
    /// side by side. Always-append is what every modern DB client
    /// (TablePlus, DBeaver, DataGrip, Beekeeper) does anyway.
    pub(super) fn dispatch_select_table(
        &mut self,
        schema: Option<String>,
        name: String,
        open_mode: OpenMode,
        sender: ComponentSender<Self>,
    ) {
        if matches!(open_mode, OpenMode::SwitchOrAppend) {
            // Multiple tabs may be open for the same (schema, table)
            // pair (Ctrl+click duplicates). Prefer the currently-
            // selected tab when it matches, then any other match.
            let existing = {
                let tabs = self.workspace_tabs.borrow();
                let selected_page = self.workspace_tab_view.as_ref().and_then(|tv| tv.selected_page());
                let matches_slot = |t: &WorkspaceTab| match t {
                    WorkspaceTab::Table(s) if s.schema.as_deref() == schema.as_deref() && s.table == name => {
                        Some(s.page.clone())
                    }
                    _ => None,
                };
                let selected_match = selected_page.and_then(|sp| {
                    let id = read_workspace_tab_id(&sp)?;
                    matches_slot(tabs.get(&id)?)
                });
                selected_match.or_else(|| tabs.values().find_map(matches_slot))
            };
            if let Some(page) = existing
                && let Some(tab_view) = self.workspace_tab_view.as_ref()
            {
                tab_view.set_selected_page(&page);
                return;
            }
        }
        // Default open path appends a Data-view Browse tab. Structure
        // for the same table opens as its own separate tab via the
        // sidebar right-click "Edit Structure" action.
        self.append_table_tab(schema, name, 0, self.default_page_size, None, sender);
    }
}

impl App {
    pub(super) fn selected_workspace_tab_id(&self) -> Option<Uuid> {
        let tab_view = self.workspace_tab_view.as_ref()?;
        let page = tab_view.selected_page()?;
        read_workspace_tab_id(&page)
    }

    pub(super) fn selected_browse_tab_id(&self) -> Option<Uuid> {
        let id = self.selected_workspace_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        let slot = tabs.get(&id)?;
        // Treat both legacy `Browse` and unified `Table` (regardless of
        // active mode) as candidates — the Browse-side controller is
        // present in both. Save / Discard / Find paths route through
        // this helper.
        if slot.browse_controller().is_some() {
            Some(id)
        } else {
            None
        }
    }

    pub(super) fn selected_browse_slot_table(&self) -> Option<(Option<String>, String)> {
        let id = self.selected_browse_tab_id()?;
        let tabs = self.workspace_tabs.borrow();
        let (schema, table) = tabs.get(&id)?.schema_table()?;
        Some((schema.map(str::to_owned), table.to_string()))
    }

    pub(super) fn sidebar_schemas_distinct(&self) -> usize {
        let distinct: std::collections::BTreeSet<&str> = self
            .sidebar_tables
            .iter()
            .chain(&self.sidebar_views)
            .filter_map(|table| table.schema.as_deref())
            .collect();
        distinct.len()
    }

    /// Refresh a browse tab's title based on its tracker dirty state.
    /// Mirrors GNOME Text Editor's leading "•" prefix convention for
    /// unsaved buffers. The base label is recomputed (not stored) so
    /// schema disambiguation stays correct if other tabs change.
    ///
    /// Also flips `set_needs_attention` on the AdwTabPage so the tab
    /// bar's pulsing dot appears for background tabs that have unsaved
    /// edits — matches AdwTabView's intended use and surfaces the
    /// dirty state when the user is in another tab. The flag is
    /// suppressed for the currently-selected tab since the user is
    /// actively looking at it (the "•" title prefix is enough cue).
    pub(super) fn refresh_browse_tab_dirty(&self, tab_id: uuid::Uuid, dirty: bool) {
        let schemas_count = self.sidebar_schemas_distinct();
        let tabs = self.workspace_tabs.borrow();
        let Some(slot) = tabs.get(&tab_id) else {
            return;
        };
        // Combined dirty state: data-side OR structure-side. The
        // Structure-side input also calls this helper via the
        // dirty-changed bus, so the Boolean ORs naturally compose.
        let WorkspaceTab::Table(s) = slot else {
            return;
        };
        let (page, schema, table) = (&s.page, s.schema.as_deref(), s.table.as_str());
        let data = crate::services::change_tracker::with_tab_ref(s.id, |tr| tr.has_pending()).unwrap_or(false);
        let structure = crate::services::structure_tracker::with_tab_ref(s.id, |tr| tr.has_pending()).unwrap_or(false);
        let combined_dirty = data || structure || dirty;
        let base = qualified_browse_tab_label(schemas_count, schema, table);
        let title = if combined_dirty { format!("• {base}") } else { base };
        page.set_title(&title);
        let is_selected = self
            .workspace_tab_view
            .as_ref()
            .and_then(|tv| tv.selected_page())
            .map(|p| &p == page)
            .unwrap_or(false);
        page.set_needs_attention(combined_dirty && !is_selected);
        self.refresh_window_title();
    }

    pub(super) fn this_window_tab_ids(&self) -> Vec<Uuid> {
        self.workspace_tabs.borrow().keys().copied().collect()
    }

    pub(super) fn window_has_pending(&self) -> bool {
        let ids = self.this_window_tab_ids();
        crate::services::change_tracker::any_pending_in(ids.iter().copied())
            || crate::services::structure_tracker::any_pending_in(ids)
    }

    pub(super) fn window_pending_browse_tabs(&self) -> Vec<Uuid> {
        crate::services::change_tracker::pending_among(self.this_window_tab_ids())
    }

    pub(super) fn window_pending_structure_tabs(&self) -> Vec<Uuid> {
        crate::services::structure_tracker::pending_among(self.this_window_tab_ids())
    }

    pub(super) fn teardown_workspace_tabs(&mut self) {
        self.cancel_persist_timer();
        self.do_persist_workspace_state_now();
        self.cancel_all_editor_runs();
        self.read_scopes.borrow_mut().cancel_all();
        // Drop per-tab pending-change trackers — disconnecting wipes
        // the connection and its row identities, so any pending edits
        // would no longer be commitable.
        for tab in self.workspace_tabs.borrow().values() {
            match tab {
                WorkspaceTab::Structure(slot) => crate::services::structure_tracker::close_tab(slot.id),
                WorkspaceTab::Table(slot) => {
                    crate::services::change_tracker::close_tab(slot.id);
                    crate::services::structure_tracker::close_tab(slot.id);
                }
                WorkspaceTab::Editor(_) => {}
            }
        }
        if let Some(root) = self.workspace_root.take()
            && self.workspace_root_added.get()
        {
            if self.workspace_outer_stack.child_by_name("tabs").is_some() {
                self.workspace_outer_stack.remove(&root);
            }
            self.workspace_root_added.set(false);
        }
        self.workspace_outer_stack.set_visible_child_name("empty");
        self.workspace_tab_view = None;
        let closed_tabs = std::mem::take(&mut *self.workspace_tabs.borrow_mut());
        drop(closed_tabs);
        *self.recent_pages.borrow_mut() = Default::default();
        self.recent_walk.borrow_mut().take();
    }

    pub(super) fn cancel_all_editor_runs(&self) {
        for tab in self.workspace_tabs.borrow().values() {
            if let WorkspaceTab::Editor(s) = tab {
                let _ = s.controller.sender().send(SqlEditorInput::Cancel);
            }
        }
    }

    /// Forward a per-tab Browse input to the right slot. Routes to the
    /// Browse-side controller in both legacy `Browse` slots and the
    /// unified `Table` slot.
    pub(super) fn dispatch_to_tab(&self, tab_id: Uuid, msg: BrowseTabInput) {
        if let Some(controller) = self
            .workspace_tabs
            .borrow()
            .get(&tab_id)
            .and_then(|t| t.browse_controller())
        {
            let _ = controller.sender().send(msg);
        }
    }

    /// Editor tab title update on query change. Mirrors what was on
    /// editor_tabs.rs::on_editor_tab_query_changed; lives here now since
    /// editor tabs are first-class workspace tabs.
    pub(super) fn on_editor_tab_query_changed(&self, id: Uuid, query: String) {
        let label = if query.trim().is_empty() {
            crate::tr!("Empty query")
        } else {
            derive_tab_label(&query)
        };
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow_mut().get_mut(&id) {
            slot.page.set_title(&label);
            // Pass empty when no extra info to clear any prior tooltip;
            // libadwaita treats empty-string as no tooltip.
            let tooltip = editor_tab_tooltip(&query, &label).unwrap_or_default();
            slot.page.set_tooltip(&tooltip);
            slot.query = query;
            Self::refresh_editor_file_title(slot);
        }
        self.persist_workspace_state();
    }

    pub(super) fn on_editor_tab_run_state_changed(&self, id: Uuid, running: bool) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow_mut().get_mut(&id) {
            slot.page.set_loading(running);
            slot.running = running;
        }
    }

    pub(super) fn any_editor_running(&self) -> bool {
        self.workspace_tabs
            .borrow()
            .values()
            .any(|tab| matches!(tab, WorkspaceTab::Editor(slot) if slot.running))
    }

    pub(super) fn dispatch_to_editor(&self, tab_id: Uuid, msg: SqlEditorInput) {
        if let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&tab_id) {
            let _ = slot.controller.sender().send(msg);
        }
    }

    pub(super) fn on_replace_active_tab_query(&mut self, text: String, sender: ComponentSender<Self>) {
        // If an editor tab is active, replace its buffer in-place. If a
        // browse tab is active (or no tab at all), fall back to opening
        // a new editor tab with the query — silent no-op was the prior
        // (annoying) behaviour for users invoking from history while
        // browsing.
        if let Some(id) = self.selected_workspace_tab_id()
            && let Some(WorkspaceTab::Editor(slot)) = self.workspace_tabs.borrow().get(&id)
        {
            let _ = slot.controller.sender().send(SqlEditorInput::ReplaceQuery(text));
            return;
        }
        self.append_editor_tab(Some(text), sender);
    }

    fn editor_tab_count(&self) -> usize {
        self.workspace_tabs
            .borrow()
            .values()
            .filter(|t| matches!(t, WorkspaceTab::Editor(_)))
            .count()
    }
}

pub(super) fn qualified_browse_tab_label(schemas_count: usize, schema: Option<&str>, table: &str) -> String {
    if schemas_count >= 2
        && let Some(s) = schema
    {
        format!("{s}.{table}")
    } else {
        table.to_string()
    }
}

fn default_editor_tab_label(n: usize) -> String {
    crate::tr!("Query {n}").replace("{n}", &n.to_string())
}

/// Returns a tooltip for a Browse tab, but only when it would add info
/// beyond the visible label. When the label is already
/// `schema.table`, or there is no schema, the tooltip would just
/// duplicate the tab title and we skip it.
fn browse_tab_tooltip(schema: Option<&str>, table: &str, label: &str) -> Option<String> {
    let s = schema?;
    let qualified = format!("{s}.{table}");
    if qualified == label { None } else { Some(qualified) }
}

fn describe_closed_tab(slot: &WorkspaceTab) -> Option<ClosedTabDescriptor> {
    match slot {
        WorkspaceTab::Editor(s) => Some(ClosedTabDescriptor::Editor { query: s.query.clone() }),
        WorkspaceTab::Table(s) => {
            let model = s.browse.model();
            let sort = model.current_sort();
            Some(ClosedTabDescriptor::Table {
                schema: s.schema.clone(),
                table: s.table.clone(),
                offset: model.current_offset(),
                page_size: model.page_size(),
                sort,
            })
        }
        WorkspaceTab::Structure(s) => match s.mode {
            // New-Table drafts have no entity to point at and lose
            // their in-progress DDL on close — nothing to reopen.
            crate::ui::structure_tab::StructureMode::New => None,
            crate::ui::structure_tab::StructureMode::Edit => Some(ClosedTabDescriptor::Structure {
                schema: s.schema.clone(),
                table: s.table.clone(),
            }),
        },
    }
}

fn push_closed_tab(
    stack: &std::rc::Rc<std::cell::RefCell<std::collections::VecDeque<ClosedTabDescriptor>>>,
    descriptor: ClosedTabDescriptor,
) {
    let mut q = stack.borrow_mut();
    if q.len() == CLOSED_TABS_CAPACITY {
        q.pop_front();
    }
    q.push_back(descriptor);
}

impl App {
    pub(super) fn on_reopen_closed_tab(&mut self, sender: ComponentSender<Self>) {
        if !self.connected {
            return;
        }
        let descriptor = self.closed_tabs_stack.borrow_mut().pop_back();
        let Some(descriptor) = descriptor else {
            // Stack empty — nothing to reopen. Toast keeps the
            // shortcut from feeling broken when the user hits it
            // before having closed anything (or after a reconnect
            // wiped the stack).
            self.show_toast(&crate::tr!("No recently closed tab"));
            return;
        };
        match descriptor {
            ClosedTabDescriptor::Editor { query } => {
                let initial = if query.is_empty() { None } else { Some(query) };
                self.append_editor_tab(initial, sender);
            }
            ClosedTabDescriptor::Table {
                schema,
                table,
                offset,
                page_size,
                sort,
            } => {
                self.append_table_tab(schema, table, offset, page_size, sort, sender);
            }
            ClosedTabDescriptor::Structure { schema, table } => {
                self.append_existing_structure_tab(schema, table, sender);
            }
        }
    }

    pub(super) fn clear_closed_tabs_stack(&self) {
        self.closed_tabs_stack.borrow_mut().clear();
    }
}

/// Returns a tooltip for an Editor tab. Empty for blank queries; for
/// non-empty queries, a 200-char preview — but only when distinct from
/// the (truncated) label, so non-truncated labels don't get a redundant
/// hover popup.
fn editor_tab_tooltip(query: &str, label: &str) -> Option<String> {
    let q = query.trim();
    if q.is_empty() {
        return None;
    }
    // Use char_indices().nth(200) to walk only the first 201 chars
    // instead of materialising the whole query as a Vec<char> via
    // chars().count(). For a multi-megabyte SQL dump this avoids an
    // O(n) scan when only a 200-char preview matters.
    let mut iter = q.char_indices();
    let mut last_idx = 0;
    for _ in 0..200 {
        match iter.next() {
            Some((i, c)) => last_idx = i + c.len_utf8(),
            None => {
                return if q == label { None } else { Some(q.to_string()) };
            }
        }
    }
    let preview = format!("{}…", &q[..last_idx]);
    if preview == label { None } else { Some(preview) }
}
