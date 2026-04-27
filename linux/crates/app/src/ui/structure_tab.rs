//! Structure workspace tab — schema-management UI for CREATE / DROP /
//! ALTER TABLE, indexes, and foreign keys.
//!
//! Stub-grade in this commit: the tab renders an `AdwStatusPage`
//! placeholder + a working Discard / Save action bar wired to the
//! per-tab `StructureChangeTracker`. The full Columns / Indexes /
//! Foreign Keys / SQL Preview ViewSwitcher comes in a follow-up
//! commit; the App routing, lifecycle, and persistence layer below
//! has to land first so the rest of the app compiles.

use std::cell::RefCell;
use std::rc::Rc;

use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{ComponentParts, ComponentSender, SimpleComponent, adw, gtk};

use tablepro_core::{ColumnInfo, ForeignKeyInfo, IndexInfo};
use uuid::Uuid;

use crate::services::structure_tracker::{self, StructureTrackerEvent};

/// Whether the Structure tab is editing an existing table or
/// drafting a brand-new one. New mode tabs start with empty
/// columns / indexes / fks; Edit mode triggers a fetch on init.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StructureMode {
    New,
    Edit,
}

#[derive(Debug)]
pub struct StructureTabInit {
    pub tab_id: Uuid,
    pub schema: Option<String>,
    /// Empty string in `New` mode until the user names + saves the
    /// table; otherwise the existing table name from the sidebar.
    pub table: String,
    pub mode: StructureMode,
    pub driver_id: String,
}

pub struct StructureTab {
    tab_id: Uuid,
    schema: Option<String>,
    table_name: String,
    mode: StructureMode,
    driver_id: String,
    columns: Vec<ColumnInfo>,
    indexes: Vec<IndexInfo>,
    foreign_keys: Vec<ForeignKeyInfo>,
    is_loading: bool,
    load_error: Option<String>,
    inner_stack: gtk::Stack,
    pending_label: gtk::Label,
    save_button: gtk::Button,
    discard_button: gtk::Button,
    drop_button: gtk::Button,
    /// Tracks whether we've previously emitted DirtyChanged so we
    /// don't spam outputs on every empty PendingCountChanged tick.
    last_dirty: Rc<RefCell<bool>>,
}

#[derive(Debug)]
pub enum StructureTabInput {
    /// Initial fetch (Edit mode only) returned. Replaces the model's
    /// columns / indexes / fks and switches the inner stack to the
    /// real editor view.
    StructureLoaded {
        columns: Vec<ColumnInfo>,
        indexes: Vec<IndexInfo>,
        fks: Vec<ForeignKeyInfo>,
    },
    /// Initial fetch failed (table dropped externally, etc.).
    LoadFailed(String),
    /// User clicked Save.
    Save,
    /// User clicked Discard.
    Discard,
    /// User clicked Drop Table.
    DropTableRequested,
    /// Tracker pending count changed.
    PendingCountChanged(usize),
    /// Tracker was wiped.
    Cleared,
    /// Save command resolved successfully on the App side. For New
    /// mode this carries the freshly-created table's canonical name
    /// so we can transition to Edit mode without asking the user.
    SaveCompleted { new_table_name: Option<String> },
    /// Save failed; tracker is intact so the user can retry.
    SaveFailed(String),
}

// Stub-grade tab; the full UI uses ShowToast for inline validation
// errors, but the placeholder action bar doesn't fire it yet.
#[allow(dead_code)]
#[derive(Debug)]
pub enum StructureTabOutput {
    /// Tracker pending state crossed empty ↔ non-empty boundary.
    /// App applies the GNOME "•" prefix to the tab title.
    DirtyChanged(bool),
    /// Tab needs introspection data fetched (Edit mode init).
    FetchStructure,
    /// User clicked Save — App should run these statements in order.
    /// Postgres wraps in BEGIN / COMMIT; MySQL / SQLite execute
    /// sequentially per the dialect's implicit-commit semantics.
    ExecuteTransaction { statements: Vec<String> },
    /// User clicked Drop Table — App shows the AdwAlertDialog
    /// confirmation flow (cross-tab close cascade lives there too).
    DropTableRequested { schema: Option<String>, table: String },
    /// Generic toast surface for inline validation errors.
    ShowToast(String),
    /// Generic alert for non-recoverable failures (load failed).
    ShowAlert { title: String, body: String },
}

impl StructureTab {
    // Accessors used by the full ViewSwitcher UI in a follow-up
    // commit; keep the API surface ready so the next layer can call
    // them without revisiting this file.
    #[allow(dead_code)]
    pub fn schema(&self) -> Option<&str> {
        self.schema.as_deref()
    }

    #[allow(dead_code)]
    pub fn table(&self) -> &str {
        &self.table_name
    }

    #[allow(dead_code)]
    pub fn mode(&self) -> StructureMode {
        self.mode
    }

    #[allow(dead_code)]
    pub fn driver_id(&self) -> &str {
        &self.driver_id
    }

    /// Update the table name + mode after a New-mode CreateTable
    /// commits successfully. App calls this through a dispatcher
    /// when SaveCompleted carries `new_table_name`.
    pub fn promote_to_edit(&mut self, new_name: String) {
        self.mode = StructureMode::Edit;
        self.table_name = new_name;
    }

    fn refresh_buttons(&self, pending_count: usize) {
        let has_pending = pending_count > 0;
        self.save_button.set_sensitive(has_pending);
        self.discard_button.set_sensitive(has_pending);
        if has_pending {
            self.pending_label
                .set_label(&crate::tr!("{n} pending changes").replace("{n}", &pending_count.to_string()));
            self.pending_label.set_visible(true);
        } else {
            self.pending_label.set_visible(false);
        }
    }
}

impl SimpleComponent for StructureTab {
    type Init = StructureTabInit;
    type Input = StructureTabInput;
    type Output = StructureTabOutput;
    type Root = adw::ToolbarView;
    type Widgets = ();

    fn init_root() -> Self::Root {
        adw::ToolbarView::new()
    }

    fn init(init: Self::Init, root: Self::Root, sender: ComponentSender<Self>) -> ComponentParts<Self> {
        // Open the per-tab tracker. Idempotent.
        structure_tracker::open_tab(init.tab_id);

        // Inner content stack: "loading" → "ready" → "error". Today's
        // stub renders a generic StatusPage in the "ready" slot; the
        // full ViewSwitcher (Columns / Indexes / FKs / SQL Preview)
        // replaces that page in the next commit.
        let inner_stack = gtk::Stack::new();
        inner_stack.set_transition_type(gtk::StackTransitionType::Crossfade);

        let loading_status = adw::StatusPage::builder()
            .icon_name("emblem-synchronizing-symbolic")
            .title(crate::tr!("Loading structure…"))
            .build();
        inner_stack.add_named(&loading_status, Some("loading"));

        let ready_status = adw::StatusPage::builder()
            .icon_name("text-x-generic-symbolic")
            .title(match init.mode {
                StructureMode::New => crate::tr!("New table"),
                StructureMode::Edit => crate::tr!("Table structure"),
            })
            .description(crate::tr!(
                "The full Columns / Indexes / Foreign Keys editor is being wired up. \
                 Save / Discard already work against the per-tab change tracker."
            ))
            .build();
        inner_stack.add_named(&ready_status, Some("ready"));

        let error_status = adw::StatusPage::builder()
            .icon_name("dialog-error-symbolic")
            .title(crate::tr!("Couldn't load structure"))
            .build();
        inner_stack.add_named(&error_status, Some("error"));

        let initial_child = match init.mode {
            StructureMode::Edit => "loading",
            StructureMode::New => "ready",
        };
        inner_stack.set_visible_child_name(initial_child);

        // Bottom action bar: pending count + Discard / Save / Drop.
        let action_bar = gtk::ActionBar::new();
        let pending_label = gtk::Label::builder().build();
        pending_label.add_css_class("dim-label");
        pending_label.set_visible(false);
        action_bar.pack_start(&pending_label);

        let discard_button = gtk::Button::builder()
            .label(crate::tr!("Discard"))
            .sensitive(false)
            .build();
        let save_button = gtk::Button::builder()
            .label(crate::tr!("Save"))
            .sensitive(false)
            .build();
        save_button.add_css_class("suggested-action");
        let drop_button = gtk::Button::builder()
            .label(crate::tr!("Drop Table…"))
            .visible(matches!(init.mode, StructureMode::Edit))
            .build();
        drop_button.add_css_class("destructive-action");

        action_bar.pack_end(&save_button);
        action_bar.pack_end(&discard_button);
        action_bar.pack_end(&drop_button);

        let sender_for_save = sender.clone();
        save_button.connect_clicked(move |_| sender_for_save.input(StructureTabInput::Save));
        let sender_for_discard = sender.clone();
        discard_button.connect_clicked(move |_| sender_for_discard.input(StructureTabInput::Discard));
        let sender_for_drop = sender.clone();
        drop_button.connect_clicked(move |_| sender_for_drop.input(StructureTabInput::DropTableRequested));

        root.set_content(Some(&inner_stack));
        root.add_bottom_bar(&action_bar);

        // Subscribe to the per-tab tracker so PendingCountChanged
        // events drive the action bar UI without us having to poll.
        let (tracker_tx, tracker_rx) = relm4::channel::<StructureTrackerEvent>();
        structure_tracker::with_tab(init.tab_id, |t| t.subscribe(tracker_tx));
        let input_for_tracker = sender.input_sender().clone();
        relm4::spawn_local(tracker_rx.forward(input_for_tracker, |event| match event {
            StructureTrackerEvent::OpsChanged(n) => StructureTabInput::PendingCountChanged(n),
            StructureTrackerEvent::Cleared => StructureTabInput::Cleared,
        }));

        // Edit mode: kick the App to fetch columns / indexes / FKs.
        if matches!(init.mode, StructureMode::Edit) {
            let _ = sender.output(StructureTabOutput::FetchStructure);
        }

        let model = StructureTab {
            tab_id: init.tab_id,
            schema: init.schema,
            table_name: init.table,
            mode: init.mode,
            driver_id: init.driver_id,
            columns: Vec::new(),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            is_loading: matches!(init.mode, StructureMode::Edit),
            load_error: None,
            inner_stack,
            pending_label,
            save_button,
            discard_button,
            drop_button,
            last_dirty: Rc::new(RefCell::new(false)),
        };

        ComponentParts { model, widgets: () }
    }

    fn update(&mut self, msg: Self::Input, sender: ComponentSender<Self>) {
        match msg {
            StructureTabInput::StructureLoaded { columns, indexes, fks } => {
                self.columns = columns;
                self.indexes = indexes;
                self.foreign_keys = fks;
                self.is_loading = false;
                self.load_error = None;
                self.inner_stack.set_visible_child_name("ready");
            }
            StructureTabInput::LoadFailed(message) => {
                self.is_loading = false;
                self.load_error = Some(message.clone());
                self.inner_stack.set_visible_child_name("error");
                let _ = sender.output(StructureTabOutput::ShowAlert {
                    title: crate::tr!("Couldn't load structure"),
                    body: message,
                });
            }
            StructureTabInput::Save => {
                let result = structure_tracker::with_tab_ref(self.tab_id, |t| t.materialize(&self.driver_id));
                match result {
                    Some(Ok(statements)) if !statements.is_empty() => {
                        self.save_button.set_sensitive(false);
                        self.discard_button.set_sensitive(false);
                        let _ = sender.output(StructureTabOutput::ExecuteTransaction { statements });
                    }
                    Some(Ok(_)) => {
                        // Empty pending — no-op.
                    }
                    Some(Err(e)) => {
                        let _ = sender.output(StructureTabOutput::ShowAlert {
                            title: crate::tr!("Cannot save"),
                            body: format!("{e}"),
                        });
                    }
                    None => {}
                }
            }
            StructureTabInput::Discard => {
                structure_tracker::with_tab(self.tab_id, |t| t.clear());
            }
            StructureTabInput::DropTableRequested => {
                let _ = sender.output(StructureTabOutput::DropTableRequested {
                    schema: self.schema.clone(),
                    table: self.table_name.clone(),
                });
            }
            StructureTabInput::PendingCountChanged(n) => {
                self.refresh_buttons(n);
                let dirty = n > 0;
                let mut last = self.last_dirty.borrow_mut();
                if *last != dirty {
                    *last = dirty;
                    let _ = sender.output(StructureTabOutput::DirtyChanged(dirty));
                }
            }
            StructureTabInput::Cleared => {
                self.refresh_buttons(0);
                let mut last = self.last_dirty.borrow_mut();
                if *last {
                    *last = false;
                    let _ = sender.output(StructureTabOutput::DirtyChanged(false));
                }
            }
            StructureTabInput::SaveCompleted { new_table_name } => {
                if let Some(name) = new_table_name {
                    self.promote_to_edit(name);
                    self.drop_button.set_visible(true);
                }
                structure_tracker::with_tab(self.tab_id, |t| t.clear());
                // Edit mode: refetch so the model reflects what the
                // server actually has now (server-side defaults,
                // generated columns, normalised types).
                if matches!(self.mode, StructureMode::Edit) {
                    let _ = sender.output(StructureTabOutput::FetchStructure);
                }
            }
            StructureTabInput::SaveFailed(message) => {
                // Re-enable the action buttons so the user can retry.
                let pending = structure_tracker::with_tab_ref(self.tab_id, |t| t.pending_count()).unwrap_or(0);
                self.refresh_buttons(pending);
                let _ = sender.output(StructureTabOutput::ShowAlert {
                    title: crate::tr!("Save failed"),
                    body: message,
                });
            }
        }
        // Keep clippy happy when the widget tree doesn't otherwise
        // reference glib via the imports above.
        let _ = glib::Type::INVALID;
    }
}
