use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use tablepro_foreign_import::review::{
    ConnectionRow, ImportReview, ImportSelection, QueryAvailability, QueryRow, Resolution, ReviewInputs, RowNote,
    TlsFileReason, apply_blocking, plan, save_queries,
};
use tablepro_foreign_import::{
    ForeignApp, ForeignAppDirs, ForeignHost, ForeignImportError, ForeignImporter, ForeignPlatform, ForeignSource,
    ForeignSslMode, ImportRequest, PasswordOffer, PasswordOutcome, PasswordSource, SavedQuerySupport, ScanDepth,
    SourceAvailability, preselect, sources_blocking,
};
use tablepro_storage::english_secret_label;

use crate::cancel_token::{CancelToken, token};
use crate::core_handle::Core;
use crate::error::CoreError;
use crate::library::{ConnectionRecord, TlsModeTag, parse_id};
use crate::runtime::on_runtime;

// The cap the core library puts on one saved query's text, which the review also holds a larger one to.
const SAVED_QUERY_BYTE_LIMIT: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForeignAppTag {
    TablePlus,
    SequelAce,
    DBeaver,
    DataGrip,
    BeekeeperStudio,
    Navicat,
    Dbx,
}

impl From<ForeignApp> for ForeignAppTag {
    fn from(app: ForeignApp) -> Self {
        match app {
            ForeignApp::TablePlus => Self::TablePlus,
            ForeignApp::SequelAce => Self::SequelAce,
            ForeignApp::DBeaver => Self::DBeaver,
            ForeignApp::DataGrip => Self::DataGrip,
            ForeignApp::BeekeeperStudio => Self::BeekeeperStudio,
            ForeignApp::Navicat => Self::Navicat,
            ForeignApp::Dbx => Self::Dbx,
        }
    }
}

impl From<ForeignAppTag> for ForeignApp {
    fn from(app: ForeignAppTag) -> Self {
        match app {
            ForeignAppTag::TablePlus => Self::TablePlus,
            ForeignAppTag::SequelAce => Self::SequelAce,
            ForeignAppTag::DBeaver => Self::DBeaver,
            ForeignAppTag::DataGrip => Self::DataGrip,
            ForeignAppTag::BeekeeperStudio => Self::BeekeeperStudio,
            ForeignAppTag::Navicat => Self::Navicat,
            ForeignAppTag::Dbx => Self::Dbx,
        }
    }
}

// Where other apps keep their files on this machine: the home folder, %APPDATA% and %LOCALAPPDATA% on Windows.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignAppDirsArg {
    pub home: String,
    pub config: String,
    pub data: String,
}

impl From<ForeignAppDirsArg> for ForeignAppDirs {
    fn from(dirs: ForeignAppDirsArg) -> Self {
        Self {
            platform: ForeignPlatform::current(),
            home: PathBuf::from(dirs.home),
            config: PathBuf::from(dirs.config),
            data: PathBuf::from(dirs.data),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PasswordSourceTag {
    // The system keychain, which another app reads only on macOS. DataGrip may keep them in a KeePass file instead.
    Keychain,
    // Its own files under a fixed key, decrypted while reading.
    AppFiles,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SavedQuerySupportTag {
    // Saved queries sit apart from the connections, and the core keeps each with a connection.
    GlobalFolder,
    // Scripts land with the connection they run on; one with a default name starts unchecked.
    Scripts,
    // Query consoles land with their data source; one with a default name starts unchecked.
    Consoles,
    NotInExport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ScanDepthTag {
    // Whether each app is there, with no count: the launch probe.
    Presence,
    Inventory,
}

impl From<ScanDepthTag> for ScanDepth {
    fn from(depth: ScanDepthTag) -> Self {
        match depth {
            ScanDepthTag::Presence => Self::Presence,
            ScanDepthTag::Inventory => Self::Inventory,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SourceAvailabilityTag {
    Available,
    NotFound,
    // The app's data is there and could not be read; code is a foreign_import.* code.
    Unreadable { code: String, detail: String },
}

impl From<&SourceAvailability> for SourceAvailabilityTag {
    fn from(availability: &SourceAvailability) -> Self {
        match availability {
            SourceAvailability::Available => Self::Available,
            SourceAvailability::NotFound => Self::NotFound,
            SourceAvailability::Unreadable(reason) => Self::Unreadable {
                code: reason.code.to_owned(),
                detail: reason.detail.clone(),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PasswordOfferTag {
    DecryptedWhileReading,
    PasswordFile,
    KeyInCredentialManager,
    // Kept where this platform does not let another app read, so passwords are not offered.
    SystemStore,
}

impl From<PasswordOffer> for PasswordOfferTag {
    fn from(offer: PasswordOffer) -> Self {
        match offer {
            PasswordOffer::DecryptedWhileReading => Self::DecryptedWhileReading,
            PasswordOffer::PasswordFile => Self::PasswordFile,
            PasswordOffer::KeyInCredentialManager => Self::KeyInCredentialManager,
            PasswordOffer::SystemStore => Self::SystemStore,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignSourceInfo {
    pub app: ForeignAppTag,
    pub name: String,
    // An app that imports from a file the user picks is always available.
    pub availability: SourceAvailabilityTag,
    pub connections: u64,
    pub saved_queries: u64,
    // The export file's extensions for an app imported from a file the user picks; empty otherwise.
    pub file_extensions: Vec<String>,
    pub passwords: PasswordSourceTag,
    pub saved_query_support: SavedQuerySupportTag,
    pub password_offer: PasswordOfferTag,
    pub offers_saved_queries: bool,
    pub starts_ticked: bool,
    // True on at most one row: the one a dialog that takes one app selects first.
    pub preselected: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ForeignImportRequest {
    pub include_passwords: bool,
    pub include_saved_queries: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PasswordOutcomeTag {
    NotRequested,
    Read,
    // A store was locked or would not answer, so the rest were not read.
    Stopped,
    // The app keeps them where this platform does not let another app read.
    LeftInKeychain,
}

impl From<PasswordOutcome> for PasswordOutcomeTag {
    fn from(outcome: PasswordOutcome) -> Self {
        match outcome {
            PasswordOutcome::NotRequested => Self::NotRequested,
            PasswordOutcome::Read => Self::Read,
            PasswordOutcome::Stopped => Self::Stopped,
            PasswordOutcome::LeftInKeychain => Self::LeftInKeychain,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ForeignSslModeTag {
    Disabled,
    Preferred,
    Required,
    VerifyCa,
    VerifyIdentity,
}

impl From<ForeignSslMode> for ForeignSslModeTag {
    fn from(mode: ForeignSslMode) -> Self {
        match mode {
            ForeignSslMode::Disabled => Self::Disabled,
            ForeignSslMode::Preferred => Self::Preferred,
            ForeignSslMode::Required => Self::Required,
            ForeignSslMode::VerifyCa => Self::VerifyCa,
            ForeignSslMode::VerifyIdentity => Self::VerifyIdentity,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TlsFileReasonTag {
    EngineLacks,
    // A CA file needs Verify Full, and a client identity needs TLS on.
    ModeLacks,
    RelativePath,
    // A certificate without its key, or a key without its certificate.
    Incomplete,
}

impl From<TlsFileReason> for TlsFileReasonTag {
    fn from(reason: TlsFileReason) -> Self {
        match reason {
            TlsFileReason::EngineLacks => Self::EngineLacks,
            TlsFileReason::ModeLacks => Self::ModeLacks,
            TlsFileReason::RelativePath => Self::RelativePath,
            TlsFileReason::Incomplete => Self::Incomplete,
        }
    }
}

// What the review tells the user about a row. Paths are as the other app wrote them.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum RowNoteInfo {
    UnsupportedEngine { engine: String },
    SshKeyMissing { path: String },
    JumpHostKeyMissing { path: String },
    CaCertificateMissing { path: String },
    ClientCertificateMissing { path: String },
    ClientKeyMissing { path: String },
    TlsModeChanged { from: ForeignSslModeTag, to: TlsModeTag },
    TlsSettingsNotRead,
    TlsFromDriverDefault { mode: ForeignSslModeTag },
    TlsNotKept { from: ForeignSslModeTag },
    CaFileNotKept { path: String, reason: TlsFileReasonTag },
    ClientIdentityNotKept { reason: TlsFileReasonTag },
    SshNotKept,
    SshKeyNotKept { path: String },
    JumpHostNotKept { host: String },
    JumpHostPasswordNotKept { host: String },
    JumpHostKeyNotKept { host: String, path: String },
    FieldsNotKept { fields: Vec<String> },
}

impl From<&RowNote> for RowNoteInfo {
    fn from(note: &RowNote) -> Self {
        match note.clone() {
            RowNote::UnsupportedEngine { engine } => Self::UnsupportedEngine { engine },
            RowNote::SshKeyMissing { path } => Self::SshKeyMissing { path },
            RowNote::JumpHostKeyMissing { path } => Self::JumpHostKeyMissing { path },
            RowNote::CaCertificateMissing { path } => Self::CaCertificateMissing { path },
            RowNote::ClientCertificateMissing { path } => Self::ClientCertificateMissing { path },
            RowNote::ClientKeyMissing { path } => Self::ClientKeyMissing { path },
            RowNote::TlsModeChanged { from, to } => Self::TlsModeChanged {
                from: from.into(),
                to: to.into(),
            },
            RowNote::TlsSettingsNotRead => Self::TlsSettingsNotRead,
            RowNote::TlsFromDriverDefault { mode } => Self::TlsFromDriverDefault { mode: mode.into() },
            RowNote::TlsNotKept { from } => Self::TlsNotKept { from: from.into() },
            RowNote::CaFileNotKept { path, reason } => Self::CaFileNotKept {
                path,
                reason: reason.into(),
            },
            RowNote::ClientIdentityNotKept { reason } => Self::ClientIdentityNotKept { reason: reason.into() },
            RowNote::SshNotKept => Self::SshNotKept,
            RowNote::SshKeyNotKept { path } => Self::SshKeyNotKept { path },
            RowNote::JumpHostNotKept { host } => Self::JumpHostNotKept { host },
            RowNote::JumpHostPasswordNotKept { host } => Self::JumpHostPasswordNotKept { host },
            RowNote::JumpHostKeyNotKept { host, path } => Self::JumpHostKeyNotKept { host, path },
            RowNote::FieldsNotKept { fields } => Self::FieldsNotKept { fields },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExistingConnectionInfo {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignConnectionRow {
    pub reference: String,
    pub name: String,
    // As the other app named it.
    pub engine: String,
    // As it would be saved; None when no engine here opens it, and such a row cannot be checked.
    pub connection: Option<ConnectionRecord>,
    pub group_path: Vec<String>,
    // The saved connection it matches by host, port, database and user.
    pub duplicate: Option<ExistingConnectionInfo>,
    pub notes: Vec<RowNoteInfo>,
    pub saved_query_count: u32,
    pub carries_passwords: bool,
}

impl From<&ConnectionRow> for ForeignConnectionRow {
    fn from(row: &ConnectionRow) -> Self {
        Self {
            reference: row.reference.clone(),
            name: row.name.clone(),
            engine: row.engine.clone(),
            connection: row.connection.as_ref().map(ConnectionRecord::from),
            group_path: row.group_path.clone(),
            duplicate: row.duplicate.as_ref().map(|existing| ExistingConnectionInfo {
                id: existing.id.to_string(),
                name: existing.name.clone(),
            }),
            notes: row.notes.iter().map(RowNoteInfo::from).collect(),
            saved_query_count: u32::try_from(row.saved_query_count).unwrap_or(u32::MAX),
            carries_passwords: row.carries_credentials,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignQueryRow {
    pub reference: String,
    pub name: String,
    // The reference of the connection row it runs on.
    pub connection: Option<String>,
    pub connection_name: Option<String>,
    pub byte_count: u64,
}

impl From<&QueryRow> for ForeignQueryRow {
    fn from(row: &QueryRow) -> Self {
        Self {
            reference: row.reference.clone(),
            name: row.name.clone(),
            connection: row.connection.clone(),
            connection_name: row.connection_name.clone(),
            byte_count: row.byte_count,
        }
    }
}

// What a row does when a saved connection matches it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ResolutionTag {
    Add,
    AddCopy,
    // Keeps the saved connection's id and secrets; offered only when both connect the same way.
    Replace { id: String },
    // Writes nothing, so the row's saved queries land on the saved connection.
    KeepExisting { id: String },
}

impl From<Resolution> for ResolutionTag {
    fn from(resolution: Resolution) -> Self {
        match resolution {
            Resolution::Add => Self::Add,
            Resolution::AddCopy => Self::AddCopy,
            Resolution::Replace(id) => Self::Replace { id: id.to_string() },
            Resolution::KeepExisting(id) => Self::KeepExisting { id: id.to_string() },
        }
    }
}

impl TryFrom<ResolutionTag> for Resolution {
    type Error = CoreError;

    fn try_from(tag: ResolutionTag) -> Result<Self, CoreError> {
        Ok(match tag {
            ResolutionTag::Add => Self::Add,
            ResolutionTag::AddCopy => Self::AddCopy,
            ResolutionTag::Replace { id } => Self::Replace(parse_id(&id)?),
            ResolutionTag::KeepExisting { id } => Self::KeepExisting(parse_id(&id)?),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignConnectionChoice {
    pub reference: String,
    pub selected: bool,
    // What a checked row does; kept across an uncheck, so checking it again restores it.
    pub resolution: Option<ResolutionTag>,
    // A Replace another checked row took is withdrawn here.
    pub offered: Vec<ResolutionTag>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum QueryAvailabilityTag {
    Available,
    // The library keeps one query per name on a connection, and an earlier row of this import takes it.
    AddedByAnotherRow,
    TooLarge,
    NameTooLong,
    // Its connection is not imported, or its Replace went to another row.
    ConnectionSkipped,
    // The other app filed it under no connection, and the library keeps each query under one.
    NoConnection,
}

impl From<QueryAvailability> for QueryAvailabilityTag {
    fn from(availability: QueryAvailability) -> Self {
        match availability {
            QueryAvailability::Available => Self::Available,
            QueryAvailability::AddedByAnotherRow => Self::AddedByAnotherRow,
            QueryAvailability::TooLarge => Self::TooLarge,
            QueryAvailability::NameTooLong => Self::NameTooLong,
            QueryAvailability::ConnectionSkipped => Self::ConnectionSkipped,
            QueryAvailability::NoConnection => Self::NoConnection,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignQueryChoice {
    pub reference: String,
    pub availability: QueryAvailabilityTag,
    pub included: bool,
}

// The review's checks as the import would write them, worked out again after every change.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignImportChoices {
    pub connections: Vec<ForeignConnectionChoice>,
    pub queries: Vec<ForeignQueryChoice>,
    // False when the plan writes nothing.
    pub importable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ForeignImportOutcome {
    // The saved connections the import wrote, added or replaced, in the review's order; Keep Existing writes none.
    pub connection_ids: Vec<String>,
    pub connections: u32,
    pub replaced: u32,
    // Passwords the secret store refused; their connections were imported without them.
    pub passwords_not_kept: u32,
    pub queries_added: u32,
    // The connection already holds a query of that name, which is left alone.
    pub queries_already_saved: u32,
    pub queries_failed: u32,
}

// Another app's connections and queries read once, checked against the library as it was then, and imported once.
#[derive(uniffi::Object)]
pub struct ForeignImportReview {
    core: Arc<Core>,
    review: ImportReview,
    selection: Mutex<ImportSelection>,
    applied: AtomicBool,
}

impl ForeignImportReview {
    fn selection(&self) -> std::sync::MutexGuard<'_, ImportSelection> {
        self.selection.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[uniffi::export]
impl ForeignImportReview {
    pub fn app(&self) -> ForeignAppTag {
        self.review.app().into()
    }

    pub fn passwords(&self) -> PasswordOutcomeTag {
        self.review.passwords().into()
    }

    pub fn connections(&self) -> Vec<ForeignConnectionRow> {
        self.review
            .connections()
            .iter()
            .map(ForeignConnectionRow::from)
            .collect()
    }

    pub fn saved_queries(&self) -> Vec<ForeignQueryRow> {
        self.review.saved_queries().iter().map(ForeignQueryRow::from).collect()
    }

    pub fn choices(&self) -> ForeignImportChoices {
        let selection = self.selection().clone();
        let planned = plan(&self.review, &selection);
        ForeignImportChoices {
            connections: self
                .review
                .connections()
                .iter()
                .map(|row| ForeignConnectionChoice {
                    reference: row.reference.clone(),
                    selected: selection.is_selected(&row.reference),
                    resolution: selection
                        .resolution(&row.reference)
                        .or_else(|| selection.offered_resolutions(row).first().copied())
                        .map(ResolutionTag::from),
                    offered: selection
                        .offered_resolutions(row)
                        .into_iter()
                        .map(ResolutionTag::from)
                        .collect(),
                })
                .collect(),
            queries: self
                .review
                .saved_queries()
                .iter()
                .map(|row| {
                    let status = planned.query_status(&row.reference);
                    ForeignQueryChoice {
                        reference: row.reference.clone(),
                        availability: status
                            .map_or(QueryAvailabilityTag::NoConnection, |status| status.availability.into()),
                        included: status.is_some_and(|status| status.included),
                    }
                })
                .collect(),
            importable: !planned.is_empty(),
        }
    }

    // A row no engine here opens stays unchecked.
    pub fn set_selected(&self, reference: String, selected: bool) {
        self.selection().set_selected(selected, &reference, &self.review);
    }

    // False when the row does not offer it, or another checked row took that Replace.
    pub fn resolve(&self, reference: String, resolution: ResolutionTag) -> Result<bool, CoreError> {
        let resolution = Resolution::try_from(resolution)?;
        Ok(self.selection().resolve(&reference, resolution, &self.review))
    }

    pub fn set_included(&self, reference: String, included: bool) {
        self.selection().set_included(included, &reference);
    }

    // Writes the checked rows once: the connections, their passwords into the secret store, then their saved queries.
    // A library that changed since the read refuses with storage.import_outdated and writes nothing.
    pub async fn apply(&self) -> Result<ForeignImportOutcome, CoreError> {
        if self.applied.swap(true, Ordering::AcqRel) {
            return Err(CoreError::failed("foreign_import.applied", "this import already ran"));
        }
        let planned = plan(&self.review, &self.selection().clone());
        let core = self.core.clone();
        let review = self.review.clone();
        let tasks = core.tasks.clone();
        let written = on_runtime(&tasks, async move { write(&core, review, planned).await }).await;
        // Refused before anything was written, so the user can read the other app again and import.
        if written.is_err() {
            self.applied.store(false, Ordering::Release);
        }
        written
    }
}

impl std::fmt::Debug for ForeignImportReview {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ForeignImportReview")
            .field("app", &self.review.app())
            .field("connections", &self.review.connections().len())
            .finish_non_exhaustive()
    }
}

async fn write(
    core: &Core,
    review: ImportReview,
    planned: tablepro_foreign_import::review::ImportPlan,
) -> Result<ForeignImportOutcome, CoreError> {
    let store = core.connection_store()?;
    let vault = core.secret_vault();
    let held = core.writes();
    let _held = held.lock().await;
    let reader = store.clone();
    let applied = core
        .tasks
        .spawn_blocking_task(move || apply_blocking(&review, &planned, &reader))
        .await
        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
    let mut passwords_not_kept = 0_u32;
    for imported in &applied.connections {
        for secret in &imported.secrets {
            let label = english_secret_label(secret.kind, &imported.connection.secret_target(secret.kind));
            if let Err(error) = vault
                .store(imported.connection.id, secret.kind, &secret.secret, &label)
                .await
            {
                tracing::warn!(code = error.code(), "a password of an imported connection was not kept");
                passwords_not_kept = passwords_not_kept.saturating_add(1);
            }
        }
    }
    let mut outcome = ForeignImportOutcome {
        connection_ids: applied
            .connections
            .iter()
            .map(|imported| imported.connection.id.to_string())
            .collect(),
        connections: count(applied.connections.len()),
        replaced: count(applied.connections.iter().filter(|imported| imported.replaced).count()),
        passwords_not_kept,
        queries_added: 0,
        queries_already_saved: 0,
        queries_failed: 0,
    };
    if applied.queries.is_empty() {
        return Ok(outcome);
    }
    match core.saved_query_database().await {
        Ok(database) => {
            let saved = save_queries(&applied, &database.database.saved_queries()).await;
            outcome.queries_added = count(saved.added);
            outcome.queries_already_saved = count(saved.already_saved);
            outcome.queries_failed = count(saved.failed);
        }
        Err(error) => {
            tracing::warn!(code = error.code(), "the saved queries of an import were not added");
            outcome.queries_failed = count(applied.queries.len());
        }
    }
    Ok(outcome)
}

fn count(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[uniffi::export]
impl Core {
    // The apps this platform has, each looked for where it keeps its files. Reads files only, never a keychain.
    pub async fn foreign_sources(
        &self,
        dirs: ForeignAppDirsArg,
        depth: ScanDepthTag,
    ) -> Result<Vec<ForeignSourceInfo>, CoreError> {
        let dirs = ForeignAppDirs::from(dirs);
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            tasks
                .spawn_blocking_task(move || source_infos(&sources_blocking(&dirs, host(), depth.into())))
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))
        })
        .await
    }

    // Reads the app's connections and saved queries, from `file` for one imported from an export the user picked, and
    // checks them against the library as it is now. Fails with a foreign_import.* code.
    pub async fn read_foreign(
        self: Arc<Self>,
        app: ForeignAppTag,
        dirs: ForeignAppDirsArg,
        file: Option<String>,
        request: ForeignImportRequest,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Arc<ForeignImportReview>, CoreError> {
        let store = self.connection_store()?;
        let dirs = ForeignAppDirs::from(dirs);
        let importer = importer(app.into(), &dirs);
        let importer = match file {
            Some(file) => importer.with_file(PathBuf::from(file)),
            None => importer,
        };
        let request = ImportRequest {
            include_passwords: request.include_passwords,
            include_saved_queries: request.include_saved_queries,
            saved_query_byte_limit: SAVED_QUERY_BYTE_LIMIT,
        };
        let cancel = token(cancel);
        let registry = self.registry();
        let core = self.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let read = tasks.spawn_blocking_task(move || {
                let collected = importer.collect_blocking(&request, &cancel).map_err(foreign_error)?;
                let library = store.list_blocking()?;
                let file_exists = |path: &Path| path.exists();
                Ok::<_, CoreError>(ImportReview::analyze(
                    collected,
                    ReviewInputs {
                        drivers: &registry,
                        library,
                        dirs: &dirs,
                        file_exists: &file_exists,
                    },
                ))
            });
            let review = read
                .await
                .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
            Ok(Arc::new(ForeignImportReview {
                selection: Mutex::new(ImportSelection::defaults(&review)),
                core,
                review,
                applied: AtomicBool::new(false),
            }))
        })
        .await
    }
}

fn source_infos(sources: &[ForeignSource]) -> Vec<ForeignSourceInfo> {
    let preselected = preselect(sources);
    sources
        .iter()
        .map(|source| {
            let app = source.app;
            ForeignSourceInfo {
                app: app.into(),
                name: app.display_name().to_owned(),
                availability: (&source.availability).into(),
                connections: source.inventory.connections as u64,
                saved_queries: source.inventory.saved_queries as u64,
                file_extensions: app
                    .picked_file_extensions()
                    .unwrap_or_default()
                    .iter()
                    .map(|extension| (*extension).to_owned())
                    .collect(),
                passwords: match app.password_source() {
                    PasswordSource::Keychain => PasswordSourceTag::Keychain,
                    PasswordSource::AppFiles => PasswordSourceTag::AppFiles,
                },
                saved_query_support: match app.saved_query_support() {
                    SavedQuerySupport::GlobalFolder => SavedQuerySupportTag::GlobalFolder,
                    SavedQuerySupport::Scripts => SavedQuerySupportTag::Scripts,
                    SavedQuerySupport::Consoles => SavedQuerySupportTag::Consoles,
                    SavedQuerySupport::NotInExport => SavedQuerySupportTag::NotInExport,
                },
                password_offer: source.password_offer.into(),
                offers_saved_queries: source.offers_saved_queries,
                starts_ticked: source.starts_ticked(),
                preselected: preselected == Some(app),
            }
        })
        .collect()
}

fn importer(app: ForeignApp, dirs: &ForeignAppDirs) -> ForeignImporter {
    ForeignImporter::new(app, dirs.clone(), host())
}

fn foreign_error(error: ForeignImportError) -> CoreError {
    match error {
        ForeignImportError::Cancelled => CoreError::Cancelled,
        error => CoreError::failed(error.code(), error.to_string()),
    }
}

#[cfg(windows)]
fn host() -> Arc<dyn ForeignHost> {
    Arc::new(WindowsHost)
}

#[cfg(not(windows))]
fn host() -> Arc<dyn ForeignHost> {
    Arc::new(tablepro_foreign_import::PlainHost)
}

// No installed-app lookup and no other app's keychain. The user's DPAPI opens a key another app sealed to them, and
// Credential Manager hands over another app's generic credential, as it does to any app the user runs.
#[cfg(windows)]
struct WindowsHost;

#[cfg(windows)]
impl ForeignHost for WindowsHost {
    fn data_protection(&self) -> Option<Arc<dyn tablepro_foreign_import::DataProtection>> {
        Some(Arc::new(dpapi::UserDataProtection))
    }

    fn credential_manager(&self) -> Option<Arc<dyn tablepro_foreign_import::ForeignCredentialManager>> {
        Some(Arc::new(UserCredentials))
    }
}

#[cfg(windows)]
struct UserCredentials;

#[cfg(windows)]
impl tablepro_foreign_import::ForeignCredentialManager for UserCredentials {
    fn read_generic(&self, target: &str) -> tablepro_foreign_import::KeychainRead {
        use tablepro_foreign_import::KeychainRead;

        match crate::credential_manager::read_generic(target) {
            Ok(Some(secret)) => KeychainRead::Found(secret),
            Ok(None) => KeychainRead::NotFound,
            Err(error) => {
                tracing::warn!(%error, "another app's credential did not read");
                KeychainRead::Denied
            }
        }
    }
}

#[cfg(windows)]
pub(crate) mod dpapi {
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Cryptography::{
        CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptUnprotectData,
    };

    // CryptUnprotectData with no prompt: IntelliJ seals its KeePass main key with no entropy, DBX its key's copy with
    // some.
    pub(crate) struct UserDataProtection;

    impl tablepro_foreign_import::DataProtection for UserDataProtection {
        fn unprotect(&self, blob: &[u8], entropy: &[u8]) -> Option<Vec<u8>> {
            let input = CRYPT_INTEGER_BLOB {
                cbData: u32::try_from(blob.len()).ok()?,
                pbData: blob.as_ptr().cast_mut(),
            };
            let entropy = CRYPT_INTEGER_BLOB {
                cbData: u32::try_from(entropy.len()).ok()?,
                pbData: entropy.as_ptr().cast_mut(),
            };
            let mut output = CRYPT_INTEGER_BLOB {
                cbData: 0,
                pbData: std::ptr::null_mut(),
            };
            // SAFETY: input and entropy point at the caller's slices for the call; output is written by the call and
            // freed by `take`.
            let ok = unsafe {
                CryptUnprotectData(
                    &input,
                    std::ptr::null_mut(),
                    optional(&entropy),
                    std::ptr::null(),
                    std::ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            };
            if ok == 0 {
                tracing::warn!("another app's data protection blob did not open for this user");
                return None;
            }
            Some(take(output))
        }
    }

    // No entropy is a null pointer, as the sealing app passed it.
    fn optional(entropy: &CRYPT_INTEGER_BLOB) -> *const CRYPT_INTEGER_BLOB {
        if entropy.cbData == 0 {
            std::ptr::null()
        } else {
            std::ptr::from_ref(entropy)
        }
    }

    // The other side, for tests: what an app seals for the signed-in user.
    #[cfg(test)]
    pub(crate) fn protect(data: &[u8], entropy: &[u8]) -> Option<Vec<u8>> {
        use windows_sys::Win32::Security::Cryptography::CryptProtectData;

        let input = CRYPT_INTEGER_BLOB {
            cbData: u32::try_from(data.len()).ok()?,
            pbData: data.as_ptr().cast_mut(),
        };
        let entropy = CRYPT_INTEGER_BLOB {
            cbData: u32::try_from(entropy.len()).ok()?,
            pbData: entropy.as_ptr().cast_mut(),
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: std::ptr::null_mut(),
        };
        // SAFETY: as in `unprotect`.
        let ok = unsafe {
            CryptProtectData(
                &input,
                std::ptr::null(),
                optional(&entropy),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        };
        (ok != 0).then(|| take(output))
    }

    fn take(blob: CRYPT_INTEGER_BLOB) -> Vec<u8> {
        if blob.pbData.is_null() {
            return Vec::new();
        }
        let length = usize::try_from(blob.cbData).unwrap_or(0);
        // SAFETY: the call that filled `blob` allocated `cbData` bytes at `pbData`, freed once copied.
        let unsealed = unsafe { std::slice::from_raw_parts_mut(blob.pbData, length) };
        let bytes = unsealed.to_vec();
        // LocalFree releases the block as it is, so the key would stay in freed memory.
        secrecy::zeroize::Zeroize::zeroize(unsealed);
        // SAFETY: `pbData` came from LocalAlloc inside the call and is freed once.
        unsafe {
            LocalFree(blob.pbData.cast());
        }
        bytes
    }

    #[cfg(test)]
    mod tests {
        use tablepro_foreign_import::DataProtection;

        use super::*;

        #[test]
        fn a_blob_sealed_for_this_user_opens_and_another_does_not() {
            let sealed = protect(b"main key", &[]).expect("a sealed blob");
            assert_eq!(
                UserDataProtection.unprotect(&sealed, &[]).as_deref(),
                Some(b"main key".as_slice())
            );
            assert_eq!(UserDataProtection.unprotect(b"not a blob", &[]), None);
        }

        #[test]
        fn a_blob_sealed_with_entropy_opens_only_with_the_same_entropy() {
            let entropy: Vec<u8> = "com.dbx.app.secret-store.v1"
                .encode_utf16()
                .flat_map(u16::to_le_bytes)
                .collect();
            let sealed = protect(b"key material", &entropy).expect("a sealed blob");

            assert_eq!(
                UserDataProtection.unprotect(&sealed, &entropy).as_deref(),
                Some(b"key material".as_slice())
            );
            assert_eq!(UserDataProtection.unprotect(&sealed, &[]), None);
            assert_eq!(UserDataProtection.unprotect(&sealed, b"other"), None);
        }
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    #[test]
    fn every_app_and_resolution_crosses_and_comes_back() {
        for app in ForeignApp::ALL {
            assert_eq!(ForeignApp::from(ForeignAppTag::from(app)), app);
        }
        let id = Uuid::new_v4();
        for resolution in [
            Resolution::Add,
            Resolution::AddCopy,
            Resolution::Replace(id),
            Resolution::KeepExisting(id),
        ] {
            assert_eq!(
                Resolution::try_from(ResolutionTag::from(resolution)).ok(),
                Some(resolution)
            );
        }
        assert!(Resolution::try_from(ResolutionTag::Replace { id: "x".to_owned() }).is_err());
    }
}
