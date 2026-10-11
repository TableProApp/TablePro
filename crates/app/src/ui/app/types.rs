use relm4::adw::prelude::*;
use relm4::gtk::glib;
use relm4::{Controller, adw};
use uuid::Uuid;

use crate::ui::browse_tab::BrowseTab;
use crate::ui::editor::SqlEditor;

#[derive(Debug, Clone)]
pub enum ClosedTabDescriptor {
    Editor {
        query: String,
    },
    Table {
        schema: Option<String>,
        table: String,
        offset: u64,
        page_size: u64,
        sort: Option<(usize, bool)>,
    },
    Structure {
        schema: Option<String>,
        table: String,
    },
}

pub(super) const CLOSED_TABS_CAPACITY: usize = 10;

pub struct EditorTabSlot {
    pub controller: Controller<SqlEditor>,
    pub page: adw::TabPage,
    pub query: String,
    pub running: bool,
    pub file: Option<EditorFile>,
}

impl EditorTabSlot {
    pub fn has_unsaved_file_changes(&self) -> bool {
        self.file.as_ref().is_some_and(|file| file.is_dirty(&self.query))
    }
}

pub struct EditorFile {
    pub path: std::path::PathBuf,
    pub version: tablepro_core::text_file::FileVersion,
    pub saved_text: String,
}

impl EditorFile {
    pub fn from_disk(file: tablepro_core::text_file::TextFile) -> Self {
        Self {
            path: file.path,
            version: file.version,
            saved_text: file.text,
        }
    }

    pub fn is_dirty(&self, query: &str) -> bool {
        self.saved_text != query
    }

    pub fn title(&self, query: &str) -> String {
        let name = self
            .path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| self.path.display().to_string());
        if self.is_dirty(query) {
            format!("• {name}")
        } else {
            name
        }
    }
}

pub struct StructureTabSlot {
    pub id: Uuid,
    pub controller: Controller<crate::ui::structure_tab::StructureTab>,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub table: String,
    pub mode: crate::ui::structure_tab::StructureMode,
}

pub struct TableTabSlot {
    pub id: Uuid,
    pub page: adw::TabPage,
    pub schema: Option<String>,
    pub table: String,
    pub browse: Controller<BrowseTab>,
}

pub enum WorkspaceTab {
    Editor(EditorTabSlot),
    Structure(StructureTabSlot),
    Table(TableTabSlot),
}

impl WorkspaceTab {
    pub fn browse_controller(&self) -> Option<&Controller<BrowseTab>> {
        match self {
            WorkspaceTab::Table(s) => Some(&s.browse),
            _ => None,
        }
    }

    pub fn structure_controller(&self) -> Option<&Controller<crate::ui::structure_tab::StructureTab>> {
        match self {
            WorkspaceTab::Structure(s) => Some(&s.controller),
            _ => None,
        }
    }

    pub fn schema_table(&self) -> Option<(Option<&str>, &str)> {
        match self {
            WorkspaceTab::Structure(s) => Some((s.schema.as_deref(), &s.table)),
            WorkspaceTab::Table(s) => Some((s.schema.as_deref(), &s.table)),
            WorkspaceTab::Editor(_) => None,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub enum OpenMode {
    SwitchOrAppend,
    NewTab,
}

fn workspace_tab_id_quark() -> glib::Quark {
    static QUARK: std::sync::OnceLock<glib::Quark> = std::sync::OnceLock::new();
    *QUARK.get_or_init(|| glib::Quark::from_str("tp-workspace-tab-id"))
}

pub(super) fn write_workspace_tab_id(page: &adw::TabPage, id: Uuid) {
    unsafe {
        page.set_qdata(workspace_tab_id_quark(), id);
    }
}

pub(super) fn read_workspace_tab_id(page: &adw::TabPage) -> Option<Uuid> {
    unsafe { page.qdata::<Uuid>(workspace_tab_id_quark()).map(|p| *p.as_ref()) }
}

#[derive(Debug, Clone, Copy)]
pub(super) enum ExportFormat {
    Csv,
    Json,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum ConnectionTransition {
    #[default]
    Idle,
    Connecting,
    AwaitingDecision,
    WaitingForRuns,
    WaitingForSaves,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchDecision {
    Stay,
    CancelRuns,
    DiscardChanges,
    SaveChanges,
}

#[derive(Debug, Clone, Copy)]
pub(super) enum StatusKind {
    Info,
    Error,
}

impl StatusKind {
    pub(super) fn icon(self) -> &'static str {
        match self {
            StatusKind::Info => "view-grid-symbolic",
            StatusKind::Error => "dialog-error-symbolic",
        }
    }
}
