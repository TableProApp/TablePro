use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use tablepro_core::ddl::{
    self, BuildDdlError, CatalogCapabilities, DatabaseChoices, DatabaseDraft, DatabaseNoun, DdlPlan,
    DropDatabaseOptions, DropSchemaOptions, DropTableOptions, KeyspaceReplication, SchemaDraft, TruncateTableOptions,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::sql_syntax::StatementAccess;
use tablepro_core::statement::SqlBuildError;
use tablepro_core::{CommitResolution, DriverError, ErrorCategory, SafeModeLevel, WriteGate, WriteReport};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};

use crate::cancel_token::{CancelToken, token};
use crate::catalog::TableName;
use crate::error::{BoxedErrorInfo, CoreError};
use crate::row_edits::{SaveGate, resolve_commit};
use crate::runtime::on_runtime;
use crate::session::DatabaseSession;

// What the engine does to whole tables, schemas and databases, so a menu offers only those.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct CatalogAbilities {
    pub truncate_table: bool,
    pub truncate_cascade: bool,
    pub truncate_restart_identity: bool,
    // The server refuses to empty a table another table's foreign key points at, whatever its rows.
    pub truncate_refused_when_referenced: bool,
    pub drop_table: bool,
    pub drop_table_cascade: bool,
    pub create_schema: bool,
    pub drop_schema: bool,
    pub drop_schema_cascade: bool,
    pub schema_owner: bool,
    pub create_database: bool,
    pub drop_database: bool,
    pub drop_database_force: bool,
    pub database_fields: DatabaseFieldsInfo,
    // The engine calls a database a keyspace.
    pub keyspaces: bool,
    // A statement can run on every server of a cluster.
    pub on_cluster: bool,
}

// The options a new database takes beside its name.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, uniffi::Record)]
pub struct DatabaseFieldsInfo {
    pub owner: bool,
    pub template: bool,
    pub encoding: bool,
    pub locale: bool,
    pub character_set: bool,
    pub collation: bool,
    pub replication: bool,
    pub tablets: bool,
    // MongoDB keeps a database only once it holds a collection.
    pub first_collection: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CharacterSetInfo {
    pub name: String,
    pub default_collation: String,
    pub collations: Vec<String>,
}

// What the server offers for a new database's options; an empty list leaves only the server's default.
#[derive(Debug, Clone, PartialEq, Eq, Default, uniffi::Record)]
pub struct DatabaseChoicesInfo {
    pub owners: Vec<String>,
    pub templates: Vec<String>,
    pub encodings: Vec<String>,
    pub locales: Vec<String>,
    pub character_sets: Vec<CharacterSetInfo>,
    pub collations: Vec<String>,
    pub clusters: Vec<String>,
    pub data_centers: Vec<String>,
    pub default_owner: Option<String>,
    pub default_encoding: Option<String>,
    pub default_locale: Option<String>,
    pub default_character_set: Option<String>,
    pub default_collation: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DataCenterReplicas {
    pub data_center: String,
    pub replicas: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ReplicationArg {
    Simple { factor: u32 },
    NetworkTopology { factors: Vec<DataCenterReplicas> },
}

// A new database or keyspace. None leaves an option to the server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DatabaseDraftArg {
    pub name: String,
    pub owner: Option<String>,
    pub template: Option<String>,
    pub encoding: Option<String>,
    pub locale: Option<String>,
    pub character_set: Option<String>,
    pub collation: Option<String>,
    pub cluster: Option<String>,
    pub replication: Option<ReplicationArg>,
    pub durable_writes: bool,
    pub tablets: Option<bool>,
    pub first_collection: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CatalogOperation {
    TruncateTable {
        table: TableName,
        cascade: bool,
        restart_identity: bool,
        cluster: Option<String>,
    },
    DropTable {
        table: TableName,
        cascade: bool,
    },
    CreateSchema {
        name: String,
        owner: Option<String>,
    },
    DropSchema {
        name: String,
        cascade: bool,
    },
    CreateDatabase {
        draft: DatabaseDraftArg,
    },
    DropDatabase {
        name: String,
        force: bool,
        cluster: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CatalogChangeOutcome {
    Done,
    // Nothing changed.
    Failed { error: BoxedErrorInfo },
    // The change may have landed in part or in full.
    Unknown { error: BoxedErrorInfo },
}

#[uniffi::export]
impl DatabaseSession {
    // From the connection's dialect now; nothing while there is no connection to ask.
    pub fn catalog_abilities(&self) -> CatalogAbilities {
        self.session()
            .current_dialect()
            .map(|dialect| abilities(&*dialect))
            .unwrap_or_default()
    }

    // The engine keeps the database for itself, so it is never offered for a drop.
    pub fn protects_database(&self, name: String) -> bool {
        self.session()
            .current_dialect()
            .is_some_and(|dialect| ddl::protects_database(&*dialect, &name))
    }

    pub fn protects_schema(&self, name: String) -> bool {
        self.session()
            .current_dialect()
            .is_some_and(|dialect| ddl::protects_schema(&*dialect, &name))
    }

    pub async fn database_choices(&self, cancel: Option<Arc<CancelToken>>) -> Result<DatabaseChoicesInfo, CoreError> {
        let session = self.session().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let choices = session
                .run_cancellable(OperationKind::Metadata, &cancel, |lease, options| async move {
                    Ok(lease.fetch_database_choices(options).await?)
                })
                .await?;
            Ok(choices.into())
        })
        .await
    }

    // The statements the operation runs, at the session's Safe Mode level now. An option the engine has no syntax
    // for, or a name it cannot take, is refused here, before anything is shown.
    pub fn plan_catalog_change(&self, operation: CatalogOperation) -> Result<Arc<CatalogChange>, CoreError> {
        let session = self.session().clone();
        let dialect = session
            .current_dialect()
            .ok_or_else(|| CoreError::failed("ffi.not_connected", "the session has no connection"))?;
        let plan = operation.plan(&*dialect).map_err(build_error)?;
        let level = session.safe_mode();
        Ok(Arc::new(CatalogChange {
            session,
            tasks: self.tasks().clone(),
            target: operation.target(),
            access: operation.access(),
            operation,
            plan,
            level,
            started: AtomicBool::new(false),
        }))
    }

    // Read the schemas again, as after one was created or dropped.
    pub async fn refresh_schemas(
        &self,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<Vec<crate::catalog::SchemaEntry>, CoreError> {
        let session = self.session().clone();
        let cancel = token(cancel);
        on_runtime(self.tasks(), async move {
            let schemas = tokio::select! {
                biased;
                () = cancel.cancelled() => return Err(CoreError::Cancelled),
                schemas = session.refresh_schemas() => schemas?,
            };
            Ok(schemas.iter().map(crate::catalog::SchemaEntry::from).collect())
        })
        .await
    }
}

// One catalog change, which runs only the statements it was planned with.
#[derive(uniffi::Object)]
pub struct CatalogChange {
    session: Arc<Session>,
    tasks: Tasks,
    operation: CatalogOperation,
    target: TableRef,
    access: StatementAccess,
    plan: DdlPlan,
    level: SafeModeLevel,
    started: AtomicBool,
}

#[uniffi::export]
impl CatalogChange {
    pub fn statements(&self) -> Vec<String> {
        self.plan.sql().into_iter().map(str::to_owned).collect()
    }

    // Emptying or dropping asks at every level but Read-only, which refuses; creating asks only where Safe Mode asks
    // before every write.
    pub fn gate(&self) -> SaveGate {
        catalog_gate(self.level, self.access, self.session.read_only())
    }

    pub fn destructive(&self) -> bool {
        self.access == StatementAccess::Destructive
    }

    // Runs the statements shown, planned again on the connection that writes them. `confirmed` says the user answered
    // the question the gate asks. Another level than the one planned at, or another plan, refuses before anything is
    // sent.
    pub async fn run(
        &self,
        confirmed: bool,
        cancel: Option<Arc<CancelToken>>,
    ) -> Result<CatalogChangeOutcome, CoreError> {
        let planned_gate = self.gate();
        match planned_gate {
            SaveGate::Refuse => {
                return Err(CoreError::failed(
                    "edit.read_only_connection",
                    "the connection is read-only",
                ));
            }
            SaveGate::Confirm if !confirmed => {
                return Err(CoreError::failed(
                    "catalog.not_confirmed",
                    "Safe Mode asks before this change and it was not answered",
                ));
            }
            _ => {}
        }
        if self.gate_now() != planned_gate {
            return Err(safe_mode_changed());
        }
        if self.started.swap(true, Ordering::AcqRel) {
            return Err(CoreError::failed("catalog.already_run", "this change already ran"));
        }
        let session = self.session.clone();
        let cancel = token(cancel);
        let operation = self.operation.clone();
        let target = self.target.clone();
        let shown = self.plan.clone();
        let (access, level) = (self.access, planned_gate);
        on_runtime(&self.tasks, async move {
            let gated = session.clone();
            let kind = shown.kind;
            let written = session
                .run_cancellable(OperationKind::Save(kind), &cancel, move |lease, options| {
                    let (operation, target, shown, gated) =
                        (operation.clone(), target.clone(), shown.clone(), gated.clone());
                    async move {
                        // Checked again on the lease, so a level saved while the change waited for it holds.
                        if catalog_gate(gated.safe_mode(), access, gated.read_only()) != level {
                            return Ok(Err(safe_mode_changed()));
                        }
                        let plan = operation.plan(&*lease.dialect()).map_err(SqlBuildError::from)?;
                        // A connection replaced since the plan can write other SQL than the user was shown.
                        if plan != shown {
                            return Ok(Err(CoreError::failed(
                                "catalog.not_as_planned",
                                "the connection would run other statements than the ones planned",
                            )));
                        }
                        Ok(Ok(lease.write_batch(&plan.into_write_batch(target), options).await?))
                    }
                })
                .await;
            let written = match written {
                Ok(Err(refused)) => return Err(refused),
                Ok(Ok(report)) => Ok(report),
                Err(error) => Err(error),
            };
            let resolution = resolve_commit(&session, &written).await;
            let outcome = outcome(written, resolution);
            if !matches!(outcome, CatalogChangeOutcome::Failed { .. }) {
                session.invalidate_columns();
            }
            Ok(outcome)
        })
        .await
    }
}

impl CatalogChange {
    fn gate_now(&self) -> SaveGate {
        catalog_gate(self.session.safe_mode(), self.access, self.session.read_only())
    }
}

impl CatalogOperation {
    fn plan(&self, dialect: &dyn SqlDialect) -> Result<DdlPlan, BuildDdlError> {
        match self {
            Self::TruncateTable {
                table,
                cascade,
                restart_identity,
                cluster,
            } => {
                let options = TruncateTableOptions {
                    cascade: *cascade,
                    restart_identity: *restart_identity,
                    cluster: cluster.clone(),
                };
                ddl::plan_truncate_table(dialect, &table.clone().into(), &options)
            }
            Self::DropTable { table, cascade } => {
                let options = DropTableOptions {
                    if_exists: false,
                    cascade: *cascade,
                };
                dialect
                    .ddl()
                    .ok_or(BuildDdlError::Unsupported(ddl::DdlOperation::DropTable))?
                    .plan_drop_table(&table.clone().into(), options)
            }
            Self::CreateSchema { name, owner } => ddl::plan_create_schema(
                dialect,
                &SchemaDraft {
                    name: name.clone(),
                    owner: owner.clone(),
                },
            ),
            Self::DropSchema { name, cascade } => {
                ddl::plan_drop_schema(dialect, name, DropSchemaOptions { cascade: *cascade })
            }
            Self::CreateDatabase { draft } => ddl::plan_create_database(dialect, &draft.clone().into()),
            Self::DropDatabase { name, force, cluster } => ddl::plan_drop_database(
                dialect,
                name,
                &DropDatabaseOptions {
                    force: *force,
                    cluster: cluster.clone(),
                },
            ),
        }
    }

    // What the write batch names: the table, or a schema or database as a schema with no table.
    fn target(&self) -> TableRef {
        match self {
            Self::TruncateTable { table, .. } | Self::DropTable { table, .. } => table.clone().into(),
            Self::CreateSchema { name, .. } | Self::DropSchema { name, .. } | Self::DropDatabase { name, .. } => {
                TableRef::new(Some(name.clone()), "")
            }
            Self::CreateDatabase { draft } => TableRef::new(Some(draft.name.clone()), ""),
        }
    }

    fn access(&self) -> StatementAccess {
        match self {
            Self::CreateSchema { .. } | Self::CreateDatabase { .. } => StatementAccess::Write,
            Self::TruncateTable { .. }
            | Self::DropTable { .. }
            | Self::DropSchema { .. }
            | Self::DropDatabase { .. } => StatementAccess::Destructive,
        }
    }
}

fn catalog_gate(level: SafeModeLevel, access: StatementAccess, read_only: bool) -> SaveGate {
    if read_only {
        return SaveGate::Refuse;
    }
    match level.gate(access) {
        WriteGate::Run => SaveGate::Run,
        WriteGate::Confirm => SaveGate::Confirm,
        WriteGate::Refuse => SaveGate::Refuse,
    }
}

fn abilities(dialect: &dyn SqlDialect) -> CatalogAbilities {
    let catalog: CatalogCapabilities = ddl::catalog_capabilities(dialect);
    let fields = catalog.database_fields;
    let ddl = dialect.ddl();
    CatalogAbilities {
        truncate_table: catalog.truncate_table,
        truncate_cascade: catalog.truncate_cascade,
        truncate_restart_identity: catalog.truncate_restart_identity,
        truncate_refused_when_referenced: catalog.truncate_refused_when_referenced,
        drop_table: ddl.is_some(),
        drop_table_cascade: ddl.is_some_and(|ddl| ddl.capabilities().drop_table_cascade),
        create_schema: catalog.create_schema,
        drop_schema: catalog.drop_schema,
        drop_schema_cascade: catalog.drop_schema_cascade,
        schema_owner: catalog.schema_owner,
        create_database: catalog.create_database,
        drop_database: catalog.drop_database,
        drop_database_force: catalog.drop_database_force,
        database_fields: DatabaseFieldsInfo {
            owner: fields.owner,
            template: fields.template,
            encoding: fields.encoding,
            locale: fields.locale,
            character_set: fields.character_set,
            collation: fields.collation,
            replication: fields.replication,
            tablets: fields.tablets,
            first_collection: fields.first_collection,
        },
        keyspaces: catalog.database_noun == DatabaseNoun::Keyspace,
        on_cluster: catalog.on_cluster,
    }
}

impl From<DatabaseDraftArg> for DatabaseDraft {
    fn from(draft: DatabaseDraftArg) -> Self {
        Self {
            name: draft.name,
            owner: draft.owner,
            template: draft.template,
            encoding: draft.encoding,
            locale: draft.locale,
            character_set: draft.character_set,
            collation: draft.collation,
            cluster: draft.cluster,
            replication: draft.replication.map(|replication| match replication {
                ReplicationArg::Simple { factor } => KeyspaceReplication::Simple { factor },
                ReplicationArg::NetworkTopology { factors } => KeyspaceReplication::NetworkTopology {
                    factors: factors
                        .into_iter()
                        .map(|factor| (factor.data_center, factor.replicas))
                        .collect(),
                },
            }),
            durable_writes: draft.durable_writes,
            tablets: draft.tablets,
            first_collection: draft.first_collection,
        }
    }
}

impl From<DatabaseChoices> for DatabaseChoicesInfo {
    fn from(choices: DatabaseChoices) -> Self {
        Self {
            owners: choices.owners,
            templates: choices.templates,
            encodings: choices.encodings,
            locales: choices.locales,
            character_sets: choices
                .character_sets
                .into_iter()
                .map(|set| CharacterSetInfo {
                    name: set.name,
                    default_collation: set.default_collation,
                    collations: set.collations,
                })
                .collect(),
            collations: choices.collations,
            clusters: choices.clusters,
            data_centers: choices.data_centers,
            default_owner: choices.defaults.owner,
            default_encoding: choices.defaults.encoding,
            default_locale: choices.defaults.locale,
            default_character_set: choices.defaults.character_set,
            default_collation: choices.defaults.collation,
        }
    }
}

// What the server holds now decides, as a row save reads it.
fn outcome(
    written: Result<WriteReport, OperationError>,
    resolution: Option<Result<CommitResolution, OperationError>>,
) -> CatalogChangeOutcome {
    let error = match written {
        Ok(_) => return CatalogChangeOutcome::Done,
        Err(error) => error,
    };
    let info = || CoreError::from(&error).into_info();
    match &error {
        OperationError::Driver(DriverError::CommitOutcomeUnknown { .. }) => match resolution {
            Some(Ok(CommitResolution::Applied)) => CatalogChangeOutcome::Done,
            Some(Ok(CommitResolution::NotApplied)) => CatalogChangeOutcome::Failed { error: info() },
            _ => CatalogChangeOutcome::Unknown { error: info() },
        },
        OperationError::Driver(DriverError::PartiallyApplied { .. }) => CatalogChangeOutcome::Unknown { error: info() },
        OperationError::Driver(driver)
            if matches!(
                driver.category(),
                ErrorCategory::Interrupted | ErrorCategory::Timeout | ErrorCategory::ConnectionLost
            ) =>
        {
            CatalogChangeOutcome::Unknown { error: info() }
        }
        OperationError::Cancelled | OperationError::Panicked(_) | OperationError::Closed => {
            CatalogChangeOutcome::Unknown { error: info() }
        }
        _ => CatalogChangeOutcome::Failed { error: info() },
    }
}

fn safe_mode_changed() -> CoreError {
    CoreError::failed(
        "catalog.safe_mode_changed",
        "the connection's Safe Mode changed after the change was planned",
    )
}

// The engine's refusal, before any SQL: an operation it has no syntax for, or a name or option it cannot take.
fn build_error(error: BuildDdlError) -> CoreError {
    let code = match &error {
        BuildDdlError::Unsupported(_) => "catalog.unsupported",
        BuildDdlError::InvalidOption {
            option: ddl::CatalogOption::Name,
            ..
        } => "catalog.invalid_name",
        BuildDdlError::InvalidOption { .. } => "catalog.invalid_option",
        _ => "catalog.refused",
    };
    CoreError::failed(code, error.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(name: &str) -> TableName {
        TableName {
            schema: None,
            name: name.to_owned(),
        }
    }

    #[test]
    fn emptying_or_dropping_asks_at_every_level_but_read_only_and_creating_asks_only_when_writes_ask() {
        let drop = CatalogOperation::DropTable {
            table: table("t"),
            cascade: false,
        };
        let create = CatalogOperation::CreateSchema {
            name: "s".to_owned(),
            owner: None,
        };
        let gates = |operation: &CatalogOperation| {
            SafeModeLevel::ALL.map(|level| catalog_gate(level, operation.access(), false))
        };

        assert_eq!(gates(&drop), [SaveGate::Confirm, SaveGate::Confirm, SaveGate::Refuse]);
        assert_eq!(gates(&create), [SaveGate::Run, SaveGate::Confirm, SaveGate::Refuse]);
        assert_eq!(
            catalog_gate(SafeModeLevel::Silent, create.access(), true),
            SaveGate::Refuse
        );
    }

    #[test]
    fn a_database_names_itself_as_a_schema_with_no_table() {
        let drop = CatalogOperation::DropDatabase {
            name: "shop".to_owned(),
            force: false,
            cluster: None,
        };

        assert_eq!(drop.target(), TableRef::new(Some("shop".to_owned()), ""));
    }

    #[test]
    fn a_refusal_carries_the_code_the_app_words() {
        assert_eq!(
            build_error(BuildDdlError::Unsupported(ddl::DdlOperation::CreateSchema)).code(),
            "catalog.unsupported"
        );
        assert_eq!(
            build_error(BuildDdlError::InvalidOption {
                option: ddl::CatalogOption::Name,
                value: " ".to_owned(),
            })
            .code(),
            "catalog.invalid_name"
        );
    }
}
