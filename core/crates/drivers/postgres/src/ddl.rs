use tablepro_core::column::{ColumnKind, ColumnType, IntegerKind, IntegerWidth, NetworkFamily, TextLength};
use tablepro_core::ddl::ddl_sql::{column_list, create_index_sql, default_sql, foreign_key_sql};
use tablepro_core::ddl::{
    BuildDdlError, CatalogCapabilities, CatalogOption, CollationName, ColumnAlteration, ColumnAttributes,
    ColumnCapabilities, ColumnCompression, ColumnDefinition, ColumnStorage, DatabaseDraft, DatabaseFields,
    DatabaseNoun, DdlCapabilities, DdlDialect, DdlOperation, DdlPlan, DraftColumn, DropDatabaseOptions,
    GeneratedStorage, IdentityStyle, NameLimit, Permission, RefusalReason, ResolvedType, TableChanges, TableDefinition,
    TableDraft, catalog_name, check_database_draft, named, refuse_drop_options,
};
use tablepro_core::dialect::SqlDialect;
use tablepro_core::meta::TableRef;
use tablepro_core::value::Value;

use crate::dialect::PgDialect;

static CAPABILITIES: DdlCapabilities = DdlCapabilities {
    create_table: true,
    rename_table: true,
    add_column: true,
    drop_column: true,
    rename_column: true,
    alter_column_type: true,
    alter_column_nullability: true,
    alter_column_default: true,
    alter_primary_key: true,
    alter_auto_increment: true,
    auto_increment_outside_primary_key: true,
    create_index: true,
    drop_index: true,
    expression_index_keys: true,
    descending_index_keys: true,
    partial_indexes: true,
    add_foreign_key: true,
    drop_foreign_key: true,
    column_comments: true,
    drop_table_cascade: true,
    column_defaults: true,
    required_columns: true,
    declared_column_order: true,
    column_collations: false,
    table_options: false,
};

const TYPE_SUGGESTIONS: &[&str] = &[
    "integer",
    "bigint",
    "smallint",
    "text",
    "varchar(255)",
    "boolean",
    "timestamp",
    "timestamp with time zone",
    "date",
    "time",
    "numeric(10, 2)",
    "real",
    "double precision",
    "uuid",
    "jsonb",
    "json",
    "bytea",
];

/// The `server_version_num` of the release that added DROP DATABASE's
/// FORCE and CREATE DATABASE's LOCALE.
const RELEASE_13: u32 = 130_000;

/// NAMEDATALEN less its terminator. The server cuts a longer name short
/// with only a notice.
const NAME_BYTES: usize = 63;

/// PostgreSQL changes a table in one ALTER TABLE: it orders the
/// subcommands itself, drops before adds, so one statement carries
/// every column change. Renames cannot share it, and indexes, comments
/// and an identity's next value are statements of their own. The write
/// runs them in one transaction, so the whole change commits or none of
/// it does.
impl DdlDialect for PgDialect {
    fn capabilities(&self) -> &DdlCapabilities {
        &CAPABILITIES
    }

    fn sql_dialect(&self) -> &dyn SqlDialect {
        self
    }

    /// Identity is added and dropped in place, so turning it on or off
    /// restates nothing else about the column.
    fn column_capabilities(&self, table: &TableDefinition, column: &ColumnDefinition) -> ColumnCapabilities {
        let mut permissions = ColumnCapabilities::standard(&CAPABILITIES, table, column);
        permissions.alter_auto_increment = identity_permission(column);
        permissions
    }

    fn type_suggestions(&self) -> &'static [&'static str] {
        TYPE_SUGGESTIONS
    }

    fn default_column_type(&self) -> &'static str {
        "text"
    }

    fn plan_create_table(&self, draft: &TableDraft) -> Result<DdlPlan, BuildDdlError> {
        draft.check_create(self)?;
        let table = TableRef::new(draft.table.schema.clone(), draft.table.name.trim());
        let mut definitions = draft
            .columns
            .iter()
            .map(|column| self.column_definition(column))
            .collect::<Result<Vec<_>, _>>()?;
        let key: Vec<String> = draft.primary_key().into_iter().map(str::to_owned).collect();
        if !key.is_empty() {
            definitions.push(format!("PRIMARY KEY ({})", column_list(self, &key)));
        }
        definitions.extend(draft.foreign_keys.iter().map(|key| foreign_key_sql(self, &table, key)));
        let mut statements = vec![format!(
            "CREATE TABLE {} (\n  {}\n)",
            self.qualify(&table),
            definitions.join(",\n  ")
        )];
        for column in &draft.columns {
            if let Some(comment) = column.comment_text() {
                statements.push(self.comment_on(&table, &column.name, Some(comment)));
            }
        }
        statements.extend(
            draft
                .indexes
                .iter()
                .filter(|index| !index.primary)
                .map(|index| create_index_sql(self, &table, index)),
        );
        Ok(DdlPlan::from_sql(statements))
    }

    fn plan_alter_table(&self, original: &TableDefinition, changes: &TableChanges) -> Result<DdlPlan, BuildDdlError> {
        changes.check(self, original)?;
        let mut statements = Vec::new();
        if let Some(name) = &changes.renamed_table {
            statements.push(format!(
                "ALTER TABLE {} RENAME TO {}",
                self.qualify(&original.table),
                self.quote_identifier(name)
            ));
        }
        let table = changes.target(&original.table);
        let qualified = self.qualify(&table);
        // A column drop takes its indexes with it, so the explicit drops
        // go first.
        for index in &changes.dropped_indexes {
            let index = TableRef::new(table.schema.clone(), index.name.clone());
            statements.push(format!("DROP INDEX {}", self.qualify(&index)));
        }

        let mut drops = Vec::new();
        for key in &changes.dropped_foreign_keys {
            drops.push(format!("DROP CONSTRAINT {}", self.quote_identifier(&key.name)));
        }
        if let Some(name) = changes.dropped_primary_key_name()? {
            drops.push(format!("DROP CONSTRAINT {}", self.quote_identifier(name)));
        }
        for column in &changes.dropped_columns {
            drops.push(format!("DROP COLUMN {}", self.quote_identifier(column.name())));
        }
        // RENAME COLUMN takes a statement of its own. The drops run before
        // it, so a column can take the name of one the change drops.
        let renames = changes.ordered_renames(original);
        let mut actions = match renames.is_empty() {
            true => drops,
            false => {
                if !drops.is_empty() {
                    statements.push(format!("ALTER TABLE {qualified} {}", drops.join(", ")));
                }
                for rename in &renames {
                    statements.push(format!(
                        "ALTER TABLE {qualified} RENAME COLUMN {} TO {}",
                        self.quote_identifier(&rename.from),
                        self.quote_identifier(&rename.to)
                    ));
                }
                Vec::new()
            }
        };
        let mut sequences = Vec::new();
        for alteration in &changes.altered_columns {
            self.alter_column(&table, alteration, &mut actions, &mut sequences)?;
        }
        for column in &changes.added_columns {
            actions.push(format!("ADD COLUMN {}", self.column_definition(column)?));
        }
        if let Some(change) = changes.primary_key.as_ref().filter(|change| !change.to.is_empty()) {
            actions.push(format!("ADD PRIMARY KEY ({})", column_list(self, &change.to)));
        }
        for key in &changes.added_foreign_keys {
            actions.push(format!("ADD {}", foreign_key_sql(self, &table, key)));
        }
        if !actions.is_empty() {
            statements.push(format!("ALTER TABLE {qualified} {}", actions.join(", ")));
        }
        statements.extend(sequences);

        let altered_comments = changes
            .altered_columns
            .iter()
            .filter(|alteration| alteration.changed.comment)
            .map(|alteration| &alteration.draft);
        let added_comments = changes
            .added_columns
            .iter()
            .filter(|column| column.comment_text().is_some());
        for column in altered_comments.chain(added_comments) {
            statements.push(self.comment_on(&table, &column.name, column.comment_text()));
        }
        statements.extend(
            changes
                .added_indexes
                .iter()
                .map(|index| create_index_sql(self, &table, index)),
        );
        DdlPlan::for_changes(changes, statements)
    }

    fn catalog_capabilities(&self) -> CatalogCapabilities {
        CatalogCapabilities {
            truncate_table: true,
            truncate_cascade: true,
            truncate_restart_identity: true,
            truncate_refused_when_referenced: false,
            create_schema: true,
            drop_schema: true,
            drop_schema_cascade: true,
            schema_owner: true,
            create_database: true,
            drop_database: true,
            drop_database_force: self.server_version_num() >= RELEASE_13,
            database_fields: DatabaseFields {
                owner: true,
                template: true,
                encoding: true,
                locale: true,
                ..DatabaseFields::default()
            },
            database_noun: DatabaseNoun::Database,
            on_cluster: false,
            name_limit: Some(NameLimit::Bytes(NAME_BYTES)),
        }
    }

    /// The server refuses to drop a template. `postgres` is only where
    /// clients connect by default, and the server drops it like any other.
    fn protects_database(&self, name: &str) -> bool {
        matches!(name, "template0" | "template1")
    }

    fn protects_schema(&self, name: &str) -> bool {
        name == "information_schema" || name.starts_with("pg_")
    }

    /// Only the options set are written, so the server's defaults hold
    /// for the rest. The server takes an encoding or locale other than
    /// the template's only from template0, so one set without a template
    /// copies template0.
    fn plan_create_database(&self, draft: &DatabaseDraft) -> Result<DdlPlan, BuildDdlError> {
        let capabilities = self.catalog_capabilities();
        check_database_draft(&capabilities, draft)?;
        let mut sql = format!(
            "CREATE DATABASE {}",
            self.quote_identifier(named(&capabilities, CatalogOption::Name, &draft.name)?)
        );
        if let Some(owner) = &draft.owner {
            sql.push_str(" OWNER ");
            sql.push_str(&self.quote_identifier(catalog_name(CatalogOption::Owner, owner)?));
        }
        match &draft.template {
            Some(template) => {
                sql.push_str(" TEMPLATE ");
                sql.push_str(&self.quote_identifier(catalog_name(CatalogOption::Template, template)?));
            }
            None if draft.encoding.is_some() || draft.locale.is_some() => sql.push_str(" TEMPLATE template0"),
            None => {}
        }
        if let Some(encoding) = &draft.encoding {
            sql.push_str(&format!(" ENCODING '{}'", encoding_name(encoding)?));
        }
        if let Some(locale) = &draft.locale {
            let locale = self.locale_literal(locale)?;
            // Before LOCALE, the two settings it stands for were set apart.
            match self.server_version_num() >= RELEASE_13 {
                true => sql.push_str(&format!(" LOCALE {locale}")),
                false => sql.push_str(&format!(" LC_COLLATE {locale} LC_CTYPE {locale}")),
            }
        }
        Ok(DdlPlan::for_databases([sql]))
    }

    fn plan_drop_database(&self, database: &str, options: &DropDatabaseOptions) -> Result<DdlPlan, BuildDdlError> {
        refuse_drop_options(&self.catalog_capabilities(), options)?;
        let force = if options.force { " WITH (FORCE)" } else { "" };
        Ok(DdlPlan::for_databases([format!(
            "DROP DATABASE {}{force}",
            self.quote_identifier(catalog_name(CatalogOption::Name, database)?)
        )]))
    }
}

/// An encoding is a string the server looks up by name, so only the
/// letters, digits, underscores and hyphens its names are spelled with
/// reach the statement.
fn encoding_name(value: &str) -> Result<&str, BuildDdlError> {
    let spelled = !value.is_empty() && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    match spelled {
        true => Ok(value),
        false => Err(BuildDdlError::InvalidOption {
            option: CatalogOption::Encoding,
            value: value.to_owned(),
        }),
    }
}

/// The type the USING clause casts to when the new type has a length.
///
/// An explicit cast to a length cuts what does not fit:
/// `'abcdefghijkl'::varchar(10)` is `abcdefghij`, and the same goes for
/// `char(n)` and `bit(n)`. So the cast stops at the type without one,
/// and the server's own assignment to the column, which ALTER applies to
/// the USING result, refuses a value that is too long, as an INSERT
/// would. A bit string takes the cast to `varbit` only from another bit
/// string: an integer has a cast to `bit(n)` and none to `varbit`.
/// `varchar` is a keyword the grammar always reads as the built-in, while
/// `bpchar` and `varbit` are names the search_path would resolve.
fn unlimited_cast(original: &ColumnKind, target: &ColumnKind) -> Option<String> {
    match (original, target) {
        (
            _,
            ColumnKind::Text {
                length: TextLength::Fixed(_),
            },
        ) => Some("pg_catalog.bpchar".to_owned()),
        (
            _,
            ColumnKind::Text {
                length: TextLength::Varying(_),
            },
        ) => Some("varchar".to_owned()),
        (ColumnKind::BitString { .. }, ColumnKind::BitString { .. }) => Some("pg_catalog.varbit".to_owned()),
        (ColumnKind::Array { element: original }, ColumnKind::Array { element: target }) => {
            unlimited_cast(original, target).map(|element| format!("{element}[]"))
        }
        _ => None,
    }
}

impl PgDialect {
    /// The ALTER TABLE actions that change one column, and the sequence
    /// restart an identity it gains needs after them.
    fn alter_column(
        &self,
        table: &TableRef,
        alteration: &ColumnAlteration,
        actions: &mut Vec<String>,
        sequences: &mut Vec<String>,
    ) -> Result<(), BuildDdlError> {
        let draft = &alteration.draft;
        let name = self.quote_identifier(&draft.name);
        let changed = alteration.changed;
        let numbering = changed.auto_increment && draft.auto_increment;
        if changed.column_type {
            let resolved = draft.column_type.resolve(self, &draft.name)?;
            // A new type takes its own default collation unless the
            // change names the one the column had.
            let collation = alteration
                .original
                .attributes
                .collation
                .as_ref()
                .filter(|_| collatable(&resolved.column_type.kind))
                .map(|collation| format!(" COLLATE {}", self.collation(collation)))
                .unwrap_or_default();
            let using = unlimited_cast(&alteration.original.info.column_type.kind, &resolved.column_type.kind)
                .unwrap_or_else(|| resolved.sql.clone());
            actions.push(format!(
                "ALTER COLUMN {name} TYPE {}{collation} USING {name}::{using}",
                resolved.sql
            ));
            actions.extend(restated_storage(&name, &alteration.original.attributes, &resolved));
        }
        // An identity column is NOT NULL whatever the switch said, and
        // turning one on sets that below.
        if changed.nullability && !numbering {
            let action = if draft.nullable {
                "DROP NOT NULL"
            } else {
                "SET NOT NULL"
            };
            actions.push(format!("ALTER COLUMN {name} {action}"));
        }
        if changed.default {
            let column_type = draft.column_type.column_type(self, &draft.name)?;
            actions.push(match default_sql(self, &draft.name, &draft.default, &column_type)? {
                Some(default) => format!("ALTER COLUMN {name} SET DEFAULT {default}"),
                None => format!("ALTER COLUMN {name} DROP DEFAULT"),
            });
        }
        if numbering {
            self.check_identity(draft)?;
            actions.push(format!("ALTER COLUMN {name} SET NOT NULL"));
            actions.push(format!("ALTER COLUMN {name} ADD GENERATED BY DEFAULT AS IDENTITY"));
            sequences.push(self.identity_restart(table, &draft.name)?);
        } else if changed.auto_increment {
            actions.push(match alteration.original.attributes.identity {
                IdentityStyle::GeneratedAlways | IdentityStyle::GeneratedByDefault => {
                    format!("ALTER COLUMN {name} DROP IDENTITY")
                }
                // A serial column numbers itself through its default;
                // the sequence stays, owned by the column.
                IdentityStyle::SequenceDefault => format!("ALTER COLUMN {name} DROP DEFAULT"),
                _ => {
                    return Err(BuildDdlError::Refused {
                        column: alteration.original.name().to_owned(),
                        operation: DdlOperation::AlterAutoIncrement,
                        reason: RefusalReason::UnreadableDefinition,
                    });
                }
            });
        }
        Ok(())
    }

    /// The column as the save leaves it has to take an identity: an
    /// integer, with no default of its own.
    fn check_identity(&self, draft: &DraftColumn) -> Result<(), BuildDdlError> {
        let refused = |reason| BuildDdlError::Refused {
            column: draft.name.clone(),
            operation: DdlOperation::AlterAutoIncrement,
            reason,
        };
        let column_type = draft.column_type.column_type(self, &draft.name)?;
        if !matches!(column_type.kind, ColumnKind::Integer(_)) {
            return Err(refused(RefusalReason::NotAnInteger));
        }
        if !draft.default.is_none() {
            return Err(refused(RefusalReason::ConflictingAttribute("DEFAULT".to_owned())));
        }
        Ok(())
    }

    /// A new identity starts at 1, so it is moved past the largest key
    /// already there. A column can still own the sequence of a serial
    /// default dropped earlier, which `pg_get_serial_sequence` may return
    /// instead, so the identity's sequence is found by its internal
    /// dependency on the column. The table goes in quoted, since
    /// `regclass` parses it as SQL, and the column name as it is. It runs
    /// in the user's session, so every function and every operator between
    /// two types is named in `pg_catalog`, which a lookalike on the
    /// search_path cannot outbid.
    fn identity_restart(&self, table: &TableRef, column: &str) -> Result<String, BuildDdlError> {
        let text = |text: String| {
            SqlDialect::literal(self, &Value::Text(text), &ColumnType::untyped_text("text")).map_err(|error| {
                BuildDdlError::Literal {
                    column: column.to_owned(),
                    error,
                }
            })
        };
        let qualified = self.qualify(table);
        Ok(format!(
            "SELECT pg_catalog.setval((SELECT d.objid::pg_catalog.regclass FROM pg_catalog.pg_depend d \
             JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) d.refobjid \
             AND a.attnum OPERATOR(pg_catalog.=) d.refobjsubid \
             JOIN pg_catalog.pg_class s ON s.oid OPERATOR(pg_catalog.=) d.objid \
             WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass \
             AND d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass \
             AND d.deptype OPERATOR(pg_catalog.=) 'i' AND s.relkind OPERATOR(pg_catalog.=) 'S' \
             AND d.refobjid OPERATOR(pg_catalog.=) {}::pg_catalog.regclass AND a.attname OPERATOR(pg_catalog.=) {}), \
             GREATEST(COALESCE(pg_catalog.max({})::pg_catalog.int8, 0), 0) OPERATOR(pg_catalog.+) 1, false) \
             FROM {qualified}",
            text(qualified.clone())?,
            text(column.to_owned())?,
            self.quote_identifier(column)
        ))
    }

    /// A column as CREATE TABLE and ADD COLUMN declare it. A column read
    /// from the catalogue keeps its collation, its identity style and its
    /// generation expression.
    fn column_definition(&self, column: &DraftColumn) -> Result<String, BuildDdlError> {
        let resolved = column.column_type.resolve(self, &column.name)?;
        let attributes = column.original.as_ref().map(|original| &original.attributes);
        // A serial column numbers itself through a sequence default, and
        // only its pseudo-type makes one again: an identity clause would
        // be another kind of column.
        let serial = attributes
            .filter(|attributes| column.auto_increment && attributes.identity == IdentityStyle::SequenceDefault)
            .and_then(|_| serial_type(&resolved.column_type));
        let declaration = serial.map_or_else(|| resolved.sql.clone(), str::to_owned);
        let mut parts = vec![self.quote_identifier(&column.name), declaration];
        if let Some(collation) = attributes.and_then(|attributes| attributes.collation.as_ref()) {
            parts.push(format!("COLLATE {}", self.collation(collation)));
        }
        if let Some(generated) = attributes.and_then(|attributes| attributes.generated.as_ref()) {
            let storage = match generated.storage {
                GeneratedStorage::Stored => "STORED",
                GeneratedStorage::Virtual => "VIRTUAL",
            };
            parts.push(format!("GENERATED ALWAYS AS ({}) {storage}", generated.expression));
        } else if column.auto_increment && serial.is_none() {
            let always = attributes.is_some_and(|attributes| attributes.identity == IdentityStyle::GeneratedAlways);
            parts.push(match always {
                true => "GENERATED ALWAYS AS IDENTITY".to_owned(),
                false => "GENERATED BY DEFAULT AS IDENTITY".to_owned(),
            });
        } else if serial.is_none()
            && let Some(default) = default_sql(self, &column.name, &column.default, &resolved.column_type)?
        {
            parts.push(format!("DEFAULT {default}"));
        }
        if !column.nullable {
            parts.push("NOT NULL".to_owned());
        }
        Ok(parts.join(" "))
    }

    fn collation(&self, collation: &CollationName) -> String {
        match &collation.schema {
            Some(schema) => format!(
                "{}.{}",
                self.quote_identifier(schema),
                self.quote_identifier(&collation.name)
            ),
            None => self.quote_identifier(&collation.name),
        }
    }

    fn comment_on(&self, table: &TableRef, column: &str, comment: Option<&str>) -> String {
        let target = format!("{}.{}", self.qualify(table), self.quote_identifier(column));
        let text = comment.map(|text| Value::Text(text.to_owned()));
        match text.and_then(|text| SqlDialect::literal(self, &text, &ColumnType::untyped_text("text")).ok()) {
            Some(literal) => format!("COMMENT ON COLUMN {target} IS {literal}"),
            None => format!("COMMENT ON COLUMN {target} IS NULL"),
        }
    }

    fn locale_literal(&self, locale: &str) -> Result<String, BuildDdlError> {
        let locale = catalog_name(CatalogOption::Locale, locale)?;
        SqlDialect::literal(self, &Value::Text(locale.to_owned()), &ColumnType::untyped_text("text")).map_err(|_| {
            BuildDdlError::InvalidOption {
                option: CatalogOption::Locale,
                value: locale.to_owned(),
            }
        })
    }
}

/// Turning numbering off drops the identity or the serial default.
/// Turning it on takes an integer column the server does not compute
/// and that has no default the identity would fight.
fn identity_permission(column: &ColumnDefinition) -> Permission {
    match column.attributes.identity {
        IdentityStyle::GeneratedAlways | IdentityStyle::GeneratedByDefault | IdentityStyle::SequenceDefault => {
            Permission::Allowed
        }
        _ if column.info.is_auto_increment => Permission::Refused(RefusalReason::UnreadableDefinition),
        _ if column.info.is_generated || column.attributes.generated.is_some() => {
            Permission::Refused(RefusalReason::GeneratedColumn)
        }
        _ if !matches!(column.info.column_type.kind, ColumnKind::Integer(_)) => {
            Permission::Refused(RefusalReason::NotAnInteger)
        }
        _ if !column.info.default.is_none() => {
            Permission::Refused(RefusalReason::ConflictingAttribute("DEFAULT".to_owned()))
        }
        _ => Permission::Allowed,
    }
}

/// A type change resets SET STORAGE and SET COMPRESSION to the new
/// type's own, so a column that set either has it restated. A type that
/// keeps every value inline refuses both, so the settings go with the
/// old type. A type this build cannot place, such as a domain or an
/// enum, is restated, and the server refuses the change if it cannot
/// take them.
fn restated_storage(name: &str, attributes: &ColumnAttributes, new_type: &ResolvedType) -> Vec<String> {
    if plain_storage(new_type) {
        return Vec::new();
    }
    let storage = attributes.storage.map(|storage| {
        let keyword = match storage {
            ColumnStorage::Plain => "PLAIN",
            ColumnStorage::Main => "MAIN",
            ColumnStorage::External => "EXTERNAL",
            ColumnStorage::Extended => "EXTENDED",
        };
        format!("ALTER COLUMN {name} SET STORAGE {keyword}")
    });
    let compression = attributes.compression.map(|compression| {
        let method = match compression {
            ColumnCompression::Pglz => "pglz",
            ColumnCompression::Lz4 => "lz4",
        };
        format!("ALTER COLUMN {name} SET COMPRESSION {method}")
    });
    storage.into_iter().chain(compression).collect()
}

/// The built-in types whose `pg_type.typstorage` is PLAIN in
/// PostgreSQL 17, by `typname`.
const PLAIN_STORAGE_TYPES: &[&str] = &[
    "aclitem",
    "bool",
    "box",
    "char",
    "cid",
    "circle",
    "date",
    "float4",
    "float8",
    "gtsvector",
    "int2",
    "int2vector",
    "int4",
    "int8",
    "interval",
    "line",
    "lseg",
    "macaddr",
    "macaddr8",
    "money",
    "name",
    "oid",
    "oidvector",
    "pg_lsn",
    "point",
    "regclass",
    "regcollation",
    "regconfig",
    "regdictionary",
    "regnamespace",
    "regoper",
    "regoperator",
    "regproc",
    "regprocedure",
    "regrole",
    "regtype",
    "tid",
    "time",
    "timestamp",
    "timestamptz",
    "timetz",
    "tsquery",
    "uuid",
    "xid",
    "xid8",
];

/// Whether PostgreSQL keeps every value of the type inline, where SET
/// STORAGE takes only PLAIN and SET COMPRESSION is refused. The kind
/// covers the standard spellings, such as `double precision`, that are
/// not a `typname`.
fn plain_storage(new_type: &ResolvedType) -> bool {
    catalog_type_name(&new_type.sql).is_some_and(|name| {
        PLAIN_STORAGE_TYPES.contains(&name.as_str())
            || matches!(
                new_type.column_type.kind,
                ColumnKind::Bool(_)
                    | ColumnKind::Integer(_)
                    | ColumnKind::Float(_)
                    | ColumnKind::Money { .. }
                    | ColumnKind::Date
                    | ColumnKind::Time { .. }
                    | ColumnKind::Timestamp { .. }
                    | ColumnKind::Interval
                    | ColumnKind::Uuid
                    | ColumnKind::Network(NetworkFamily::MacAddr | NetworkFamily::MacAddr8)
            )
    })
}

/// The `typname` of the built-in type a declaration names: unquoted
/// words fold to lower case and `char` alone means `bpchar`, while a
/// quoted `"char"` is the one-byte type. `None` for an array or a type
/// in a schema other than `pg_catalog`.
fn catalog_type_name(declaration: &str) -> Option<String> {
    let text = declaration.trim();
    let lowered = text.to_ascii_lowercase();
    if text.contains('[') || lowered.split_whitespace().next_back() == Some("array") {
        return None;
    }
    let text = if lowered.starts_with("pg_catalog.") {
        &text["pg_catalog.".len()..]
    } else {
        text.strip_prefix("\"pg_catalog\".").unwrap_or(text)
    };
    if let Some(quoted) = text.strip_prefix('"') {
        let (name, rest) = quoted.split_once('"')?;
        return (!rest.starts_with('.')).then(|| name.to_owned());
    }
    let word: String = text
        .chars()
        .take_while(|c| !c.is_whitespace() && *c != '(')
        .collect::<String>()
        .to_ascii_lowercase();
    match word.as_str() {
        "char" | "character" => Some("bpchar".to_owned()),
        _ if word.contains(['.', '"']) => None,
        _ => Some(word),
    }
}

/// Whether a type takes a COLLATE clause: text, and arrays of it.
fn collatable(kind: &ColumnKind) -> bool {
    match kind {
        ColumnKind::Text { .. } => true,
        ColumnKind::Array { element } => collatable(element),
        _ => false,
    }
}

fn serial_type(column_type: &ColumnType) -> Option<&'static str> {
    match &column_type.kind {
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W16,
            ..
        }) => Some("smallserial"),
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            ..
        }) => Some("serial"),
        ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            ..
        }) => Some("bigserial"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnDefault, ColumnInfo, SqlExpression};
    use tablepro_core::ddl::{
        ColumnAttributes, DraftType, DropSchemaOptions, DropTableOptions, InboundForeignKey, KeyspaceReplication,
        PrimaryKeyConstraint, ReferentialAction, SchemaDraft, TruncateTableOptions, catalog_capabilities, diff_table,
        plan_create_database, plan_create_schema, plan_drop_database, plan_drop_schema, plan_truncate_table,
        protects_database, protects_schema,
    };
    use tablepro_core::meta::{IndexInfo, IndexKey};
    use tablepro_core::{ForeignKeyInfo, ServerInfo, WriteKind};

    use super::*;

    fn dialect() -> PgDialect {
        PgDialect::new(&ServerInfo::new("PostgreSQL", "18.0", 18, 0, 0))
    }

    fn column(name: &str, declaration: &str, primary_key: bool) -> ColumnDefinition {
        let parsed = dialect()
            .parse_type(declaration)
            .expect("a type the test dialect parses");
        ColumnDefinition::new(
            ColumnInfo {
                name: name.to_owned(),
                column_type: parsed,
                nullable: !primary_key,
                primary_key,
                is_auto_increment: false,
                is_generated: false,
                partition_scoped: false,
                default: ColumnDefault::None,
                comment: None,
            },
            ColumnAttributes::default(),
        )
    }

    fn users() -> TableDefinition {
        TableDefinition {
            table: TableRef::new(Some("app".to_owned()), "users"),
            columns: vec![
                column("id", "integer", true),
                column("email", "text", false),
                column("status", "integer", false),
            ],
            primary_key: Some(PrimaryKeyConstraint {
                name: Some("users_pkey".to_owned()),
                columns: vec!["id".to_owned()],
            }),
            indexes: Vec::new(),
            foreign_keys: Vec::new(),
            inbound_foreign_keys: Vec::new(),
            source: None,
            options: None,
        }
    }

    fn typed(name: &str, declaration: &str) -> DraftColumn {
        DraftColumn::new(name, DraftType::Typed(declaration.to_owned()))
    }

    fn alter(original: &TableDefinition, edit: impl FnOnce(&mut TableDraft)) -> Result<DdlPlan, BuildDdlError> {
        let mut draft = TableDraft::from_definition(original);
        edit(&mut draft);
        dialect().plan_alter_table(original, &diff_table(original, &draft))
    }

    fn sql(plan: Result<DdlPlan, BuildDdlError>) -> Vec<String> {
        plan.expect("the change plans")
            .sql()
            .into_iter()
            .map(str::to_owned)
            .collect()
    }

    #[test]
    fn plan_create_table_simple() {
        let mut draft = TableDraft::new(TableRef::new(Some("app".to_owned()), "notes"));
        let mut id = typed("id", "bigint");
        id.primary_key = true;
        id.nullable = false;
        id.auto_increment = true;
        let mut body = typed("body", "text");
        body.nullable = false;
        body.default = ColumnDefault::Literal(Value::Text("it's".to_owned()));
        body.comment = Some("the note".to_owned());
        let mut created = typed("created_at", "timestamp with time zone");
        created.default = ColumnDefault::Expression(SqlExpression::from_catalog_text("now()"));
        draft.columns = vec![id, body, created];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"app\".\"notes\" (\n  \"id\" bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,\n  \
                 \"body\" text DEFAULT 'it''s' NOT NULL,\n  \"created_at\" timestamp with time zone DEFAULT now(),\n  \
                 PRIMARY KEY (\"id\")\n)",
                "COMMENT ON COLUMN \"app\".\"notes\".\"body\" IS 'the note'",
            ]
        );
    }

    #[test]
    fn the_script_keeps_serial_and_identity_columns_apart() {
        let mut table = users();
        let numbered = |column: &mut ColumnDefinition, identity: IdentityStyle| {
            column.info.is_auto_increment = true;
            column.attributes.identity = identity;
        };
        numbered(&mut table.columns[0], IdentityStyle::SequenceDefault);
        let mut ticket = column("ticket", "bigint", false);
        numbered(&mut ticket, IdentityStyle::GeneratedAlways);
        table.columns.push(ticket);

        assert_eq!(
            sql(dialect().create_table_script(&table)),
            [
                "CREATE TABLE \"app\".\"users\" (\n  \"id\" serial NOT NULL,\n  \"email\" text,\n  \"status\" \
                 integer,\n  \"ticket\" bigint GENERATED ALWAYS AS IDENTITY,\n  PRIMARY KEY (\"id\")\n)"
            ]
        );
    }

    #[test]
    fn the_script_states_an_index_as_the_server_printed_it() {
        let mut table = users();
        let keys = |name: &str| IndexKey::Column {
            name: name.to_owned(),
            descending: false,
        };
        let index = |name: &str, definition: Option<&str>| IndexInfo {
            name: name.to_owned(),
            keys: vec![keys("email")],
            unique: false,
            primary: false,
            predicate: None,
            definition: definition.map(str::to_owned),
        };
        table.indexes = vec![
            index(
                "by_email",
                Some("CREATE INDEX by_email ON app.users USING gin (email gin_trgm_ops)"),
            ),
            index("users_email_key", None),
        ];

        assert_eq!(
            sql(dialect().create_table_script(&table))[1..],
            [
                "CREATE INDEX \"users_email_key\" ON \"app\".\"users\" (\"email\")",
                "CREATE INDEX by_email ON app.users USING gin (email gin_trgm_ops)",
            ]
        );
    }

    #[test]
    fn plan_create_table_composite_key_index_and_foreign_key() {
        let mut draft = TableDraft::new(TableRef::unqualified("lines"));
        let mut order = typed("order_id", "integer");
        order.primary_key = true;
        order.nullable = false;
        let mut line = typed("line", "integer");
        line.primary_key = true;
        line.nullable = false;
        draft.columns = vec![order, line, typed("sku", "text")];
        draft.indexes = vec![IndexInfo {
            name: "lines_by_sku".to_owned(),
            keys: vec![IndexKey::Column {
                name: "sku".to_owned(),
                descending: true,
            }],
            unique: true,
            primary: false,
            predicate: None,
            definition: None,
        }];
        draft.foreign_keys = vec![ForeignKeyInfo {
            name: "lines_order_fk".to_owned(),
            columns: vec!["order_id".to_owned()],
            ref_schema: None,
            ref_table: "orders".to_owned(),
            ref_columns: vec!["id".to_owned()],
            on_delete: Some(ReferentialAction::Cascade),
            on_update: Some(ReferentialAction::NoAction),
        }];

        assert_eq!(
            sql(dialect().plan_create_table(&draft)),
            [
                "CREATE TABLE \"lines\" (\n  \"order_id\" integer NOT NULL,\n  \"line\" integer NOT NULL,\n  \
                 \"sku\" text,\n  PRIMARY KEY (\"order_id\", \"line\"),\n  CONSTRAINT \"lines_order_fk\" FOREIGN KEY \
                 (\"order_id\") REFERENCES \"orders\" (\"id\") ON DELETE CASCADE\n)",
                "CREATE UNIQUE INDEX \"lines_by_sku\" ON \"lines\" (\"sku\" DESC)",
            ]
        );
    }

    #[test]
    fn plan_alter_table_nullability_type_and_default_in_one_statement() {
        let plan = alter(&users(), |draft| {
            let status = &mut draft.columns[2];
            status.column_type = DraftType::Typed("bigint".to_owned());
            status.nullable = false;
            status.default = ColumnDefault::Literal(Value::Int(0));
            draft.columns[1].default = ColumnDefault::Expression(SqlExpression::from_catalog_text("'x'"));
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"email\" SET DEFAULT 'x', ALTER COLUMN \"status\" TYPE \
              bigint USING \"status\"::bigint, ALTER COLUMN \"status\" SET NOT NULL, ALTER COLUMN \"status\" SET \
              DEFAULT 0"
            ]
        );
    }

    #[test]
    fn pg_type_change_keeps_collation_for_text_only() {
        let mut original = users();
        original.columns[1].attributes.collation = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
        let mut code = column("code", "character varying(10)", false);
        code.attributes.collation = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
        original.columns.push(code);

        let plan = alter(&original, |draft| {
            draft.columns[1].column_type = DraftType::Typed("varchar(320)".to_owned());
            draft.columns[3].column_type = DraftType::Typed("integer".to_owned());
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"email\" TYPE varchar(320) COLLATE \
                 \"pg_catalog\".\"C\" USING \"email\"::varchar, ALTER COLUMN \"code\" TYPE integer USING \
                 \"code\"::integer"
            ]
        );
        assert!(collatable(&dialect().parse_type("text[]").expect("a type").kind));
        assert!(!collatable(&dialect().parse_type("uuid").expect("a type").kind));
    }

    #[test]
    fn a_length_cast_stops_at_the_type_without_one() {
        let kind = |declaration: &str| dialect().parse_type(declaration).expect("a type").kind;
        let using = |from: &str, to: &str| unlimited_cast(&kind(from), &kind(to));

        assert_eq!(using("varchar(255)", "varchar(10)").as_deref(), Some("varchar"));
        assert_eq!(using("text", "character(5)").as_deref(), Some("pg_catalog.bpchar"));
        assert_eq!(using("bit(8)", "bit(4)").as_deref(), Some("pg_catalog.varbit"));
        assert_eq!(using("varchar(20)[]", "varchar(5)[]").as_deref(), Some("varchar[]"));
        assert_eq!(using("integer", "bit(4)"), None, "an integer has no cast to varbit");
        assert_eq!(using("text", "integer"), None);
        assert_eq!(using("numeric(10,2)", "numeric(5,2)"), None);
    }

    #[test]
    fn a_type_change_restates_storage_and_compression_the_new_type_takes() {
        let mut original = users();
        for column in &mut original.columns[1..] {
            column.attributes.storage = Some(ColumnStorage::External);
            column.attributes.compression = Some(ColumnCompression::Lz4);
        }

        let plan = alter(&original, |draft| {
            draft.columns[1].column_type = DraftType::Typed("varchar(320)".to_owned());
            draft.columns[2].column_type = DraftType::Typed("bigint".to_owned());
        });
        let nullability_only = alter(&original, |draft| draft.columns[1].nullable = false);

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"email\" TYPE varchar(320) USING \
                 \"email\"::varchar, ALTER COLUMN \"email\" SET STORAGE EXTERNAL, ALTER COLUMN \"email\" SET \
                 COMPRESSION lz4, ALTER COLUMN \"status\" TYPE bigint USING \"status\"::bigint"
            ]
        );
        assert_eq!(
            sql(nullability_only),
            ["ALTER TABLE \"app\".\"users\" ALTER COLUMN \"email\" SET NOT NULL"]
        );
    }

    #[test]
    fn only_a_type_that_keeps_its_values_inline_drops_the_settings() {
        let plain = |declaration: &str| {
            let resolved = DraftType::Typed(declaration.to_owned())
                .resolve(&dialect(), "c")
                .expect("a type");
            plain_storage(&resolved)
        };

        for declaration in [
            "point",
            "pg_catalog.lseg",
            "line",
            "box",
            "circle",
            "pg_lsn",
            "\"char\"",
            "name",
            "tsquery",
            "oid",
            "double precision",
            "timestamp(3) with time zone",
            "\"pg_catalog\".\"int4\"",
        ] {
            assert!(plain(declaration), "{declaration}");
        }
        for declaration in [
            "char(2)",
            "character",
            "text",
            "polygon",
            "numeric(10, 2)",
            "integer[]",
            "geometry",
            "public.point",
            "\"Point\"",
            "mood",
            "int4range",
            "tsvector",
        ] {
            assert!(!plain(declaration), "{declaration}");
        }
    }

    #[test]
    fn rename_then_alter_uses_new_name() {
        let plan = alter(&users(), |draft| {
            draft.table.name = "members".to_owned();
            draft.columns[1].name = "mail".to_owned();
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" RENAME TO \"members\"",
                "ALTER TABLE \"app\".\"members\" RENAME COLUMN \"email\" TO \"mail\"",
                "ALTER TABLE \"app\".\"members\" ALTER COLUMN \"mail\" SET NOT NULL",
            ]
        );
    }

    #[test]
    fn a_swap_steps_aside_and_a_dropped_name_is_free_for_a_rename() {
        let swapped = alter(&users(), |draft| {
            draft.columns[1].name = "status".to_owned();
            draft.columns[2].name = "email".to_owned();
        });
        let replaced = alter(&users(), |draft| {
            draft.columns.remove(2);
            draft.columns[1].name = "status".to_owned();
            draft.columns.push(typed("email", "text"));
        });

        assert_eq!(
            sql(swapped),
            [
                "ALTER TABLE \"app\".\"users\" RENAME COLUMN \"email\" TO \"__tablepro_rename_1\"",
                "ALTER TABLE \"app\".\"users\" RENAME COLUMN \"status\" TO \"email\"",
                "ALTER TABLE \"app\".\"users\" RENAME COLUMN \"__tablepro_rename_1\" TO \"status\"",
            ]
        );
        assert_eq!(
            sql(replaced),
            [
                "ALTER TABLE \"app\".\"users\" DROP COLUMN \"status\"",
                "ALTER TABLE \"app\".\"users\" RENAME COLUMN \"email\" TO \"status\"",
                "ALTER TABLE \"app\".\"users\" ADD COLUMN \"email\" text",
            ]
        );
    }

    #[test]
    fn a_cleared_default_and_comment_are_dropped() {
        let mut original = users();
        original.columns[2].info.default = ColumnDefault::Literal(Value::Int(1));
        original.columns[2].info.comment = Some("state".to_owned());

        let plan = alter(&original, |draft| {
            draft.columns[2].default = ColumnDefault::None;
            draft.columns[2].comment = None;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"status\" DROP DEFAULT",
                "COMMENT ON COLUMN \"app\".\"users\".\"status\" IS NULL",
            ]
        );
    }

    #[test]
    fn a_primary_key_change_drops_the_named_constraint_and_adds_the_key() {
        let plan = alter(&users(), |draft| {
            draft.columns[1].primary_key = true;
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" DROP CONSTRAINT \"users_pkey\", ALTER COLUMN \"email\" SET NOT NULL, \
              ADD PRIMARY KEY (\"id\", \"email\")"
            ]
        );
    }

    #[test]
    fn dropped_indexes_go_before_the_combined_alter_and_new_ones_after() {
        let mut original = users();
        original.indexes = vec![IndexInfo {
            name: "by_email".to_owned(),
            keys: vec![IndexKey::Column {
                name: "email".to_owned(),
                descending: false,
            }],
            unique: false,
            primary: false,
            predicate: None,
            definition: None,
        }];

        let plan = alter(&original, |draft| {
            draft.indexes.clear();
            draft.columns.retain(|column| column.name != "email");
            draft.columns.push(typed("nickname", "text"));
            draft.indexes.push(IndexInfo {
                name: "by_lower_nickname".to_owned(),
                keys: vec![IndexKey::Expression {
                    sql: "lower(nickname)".to_owned(),
                    descending: false,
                }],
                unique: false,
                primary: false,
                predicate: Some("nickname IS NOT NULL".to_owned()),
                definition: None,
            });
        });

        assert_eq!(
            sql(plan),
            [
                "DROP INDEX \"app\".\"by_email\"",
                "ALTER TABLE \"app\".\"users\" DROP COLUMN \"email\", ADD COLUMN \"nickname\" text",
                "CREATE INDEX \"by_lower_nickname\" ON \"app\".\"users\" ((lower(nickname))) WHERE nickname IS NOT \
                 NULL",
            ]
        );
    }

    fn referenced(table: &mut TableDefinition, column: &str) {
        table.inbound_foreign_keys = vec![InboundForeignKey {
            child_compares_alike: true,
            name: "orders_user_fk".to_owned(),
            table: TableRef::new(Some("app".to_owned()), "orders"),
            columns: vec!["user_id".to_owned()],
            referenced_columns: vec![column.to_owned()],
        }];
    }

    #[test]
    fn primary_key_referenced_by_foreign_key_is_refused() {
        let mut table = users();
        referenced(&mut table, "id");

        let permissions = dialect().column_capabilities(&table, &table.columns[1]);
        let plan = alter(&table, |draft| {
            draft.columns[1].primary_key = true;
            draft.columns[1].nullable = false;
        });

        assert_eq!(
            permissions.alter_primary_key,
            Permission::Refused(RefusalReason::ReferencedByForeignKeys(vec![
                "orders_user_fk".to_owned()
            ]))
        );
        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::AlterPrimaryKey,
                    reason: RefusalReason::ReferencedByForeignKeys(_),
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn drop_of_referenced_column_is_refused() {
        let mut table = users();
        referenced(&mut table, "email");

        let plan = alter(&table, |draft| draft.columns.retain(|column| column.name != "email"));

        assert!(
            matches!(
                &plan,
                Err(BuildDdlError::Refused {
                    column,
                    operation: DdlOperation::DropColumn,
                    reason: RefusalReason::ReferencedByForeignKeys(keys),
                }) if column == "email" && keys == &["orders_user_fk".to_owned()]
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn identity_on_emits_setval_after_add() {
        let mut table = users();
        table.table = TableRef::new(Some("App".to_owned()), "Users");
        table.columns[2].info.name = "Status".to_owned();

        let plan = alter(&table, |draft| {
            draft.columns[2].primary_key = true;
            draft.columns[2].nullable = false;
            draft.columns[2].auto_increment = true;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"App\".\"Users\" DROP CONSTRAINT \"users_pkey\", ALTER COLUMN \"Status\" SET NOT \
                 NULL, ALTER COLUMN \"Status\" ADD GENERATED BY DEFAULT AS IDENTITY, ADD PRIMARY KEY (\"id\", \
                 \"Status\")",
                "SELECT pg_catalog.setval((SELECT d.objid::pg_catalog.regclass FROM pg_catalog.pg_depend d \
                 JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) d.refobjid AND a.attnum \
                 OPERATOR(pg_catalog.=) d.refobjsubid JOIN pg_catalog.pg_class s ON s.oid OPERATOR(pg_catalog.=) \
                 d.objid WHERE d.classid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass AND \
                 d.refclassid OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass AND d.deptype \
                 OPERATOR(pg_catalog.=) 'i' AND s.relkind OPERATOR(pg_catalog.=) 'S' AND d.refobjid \
                 OPERATOR(pg_catalog.=) '\"App\".\"Users\"'::pg_catalog.regclass AND a.attname \
                 OPERATOR(pg_catalog.=) 'Status'), GREATEST(COALESCE(pg_catalog.max(\"Status\")::pg_catalog.int8, \
                 0), 0) OPERATOR(pg_catalog.+) 1, false) FROM \"App\".\"Users\"",
            ]
        );
    }

    #[test]
    fn identity_off_drops_the_identity_or_the_serial_default() {
        let mut table = users();
        table.columns[0].info.is_auto_increment = true;
        table.columns[0].attributes.identity = IdentityStyle::GeneratedAlways;
        table.columns[2].info.is_auto_increment = true;
        table.columns[2].attributes.identity = IdentityStyle::SequenceDefault;

        let plan = alter(&table, |draft| {
            draft.columns[0].auto_increment = false;
            draft.columns[2].auto_increment = false;
        });

        assert_eq!(
            sql(plan),
            [
                "ALTER TABLE \"app\".\"users\" ALTER COLUMN \"id\" DROP IDENTITY, ALTER COLUMN \"status\" DROP \
                 DEFAULT"
            ]
        );
    }

    #[test]
    fn identity_takes_only_an_integer_without_a_default() {
        let mut table = users();
        table.columns[2].info.default = ColumnDefault::Literal(Value::Int(1));
        let text = dialect().column_capabilities(&table, &table.columns[1]);
        let defaulted = dialect().column_capabilities(&table, &table.columns[2]);
        let plain = dialect().column_capabilities(&users(), &users().columns[2]);

        let retyped = alter(&users(), |draft| {
            draft.columns[2].column_type = DraftType::Typed("text".to_owned());
            draft.columns[2].auto_increment = true;
        });
        let given_a_default = alter(&users(), |draft| {
            draft.columns[2].default = ColumnDefault::Literal(Value::Int(1));
            draft.columns[2].auto_increment = true;
        });

        assert_eq!(
            text.alter_auto_increment,
            Permission::Refused(RefusalReason::NotAnInteger)
        );
        assert_eq!(
            defaulted.alter_auto_increment,
            Permission::Refused(RefusalReason::ConflictingAttribute("DEFAULT".to_owned()))
        );
        assert_eq!(plain.alter_auto_increment, Permission::Allowed);
        for (plan, reason) in [
            (retyped, RefusalReason::NotAnInteger),
            (
                given_a_default,
                RefusalReason::ConflictingAttribute("DEFAULT".to_owned()),
            ),
        ] {
            assert_eq!(
                plan,
                Err(BuildDdlError::Refused {
                    column: "status".to_owned(),
                    operation: DdlOperation::AlterAutoIncrement,
                    reason,
                })
            );
        }
    }

    #[test]
    fn a_key_the_catalogue_did_not_name_is_not_moved() {
        let mut table = users();
        table.primary_key = None;

        let plan = alter(&table, |draft| {
            draft.columns[2].primary_key = true;
            draft.columns[2].nullable = false;
        });

        assert!(
            matches!(
                plan,
                Err(BuildDdlError::Refused {
                    operation: DdlOperation::AlterPrimaryKey,
                    reason: RefusalReason::UnreadableDefinition,
                    ..
                })
            ),
            "{plan:?}"
        );
    }

    #[test]
    fn a_typed_type_is_refused_before_it_reaches_the_server() {
        let plan = alter(&users(), |draft| {
            draft.columns[2].column_type = DraftType::Typed("int; DROP TABLE users".to_owned());
        });

        assert!(matches!(plan, Err(BuildDdlError::InvalidType { .. })), "{plan:?}");
    }

    #[test]
    fn a_rename_stays_in_its_schema_and_a_drop_can_cascade() {
        let drop = dialect().plan_drop_table(
            &TableRef::new(Some("app".to_owned()), "users"),
            DropTableOptions {
                if_exists: true,
                cascade: true,
            },
        );

        assert_eq!(sql(drop), ["DROP TABLE IF EXISTS \"app\".\"users\" CASCADE"]);
    }

    #[test]
    fn the_script_restates_identity_collation_and_generated_columns() {
        let mut table = users();
        table.columns[0].info.is_auto_increment = true;
        table.columns[0].attributes.identity = IdentityStyle::GeneratedAlways;
        table.columns[1].attributes.collation = Some(CollationName::new(Some("pg_catalog".to_owned()), "C"));
        let mut total = column("total", "integer", false);
        total.info.is_generated = true;
        total.attributes.generated = Some(tablepro_core::ddl::GeneratedColumn {
            expression: SqlExpression::from_catalog_text("(status * 2)"),
            storage: GeneratedStorage::Stored,
        });
        table.columns.push(total);

        let script = sql(dialect().create_table_script(&table));

        assert_eq!(
            script,
            [
                "CREATE TABLE \"app\".\"users\" (\n  \"id\" integer GENERATED ALWAYS AS IDENTITY NOT NULL,\n  \"email\" \
              text COLLATE \"pg_catalog\".\"C\",\n  \"status\" integer,\n  \"total\" integer GENERATED ALWAYS AS \
              ((status * 2)) STORED,\n  PRIMARY KEY (\"id\")\n)"
            ]
        );
    }

    #[test]
    fn every_type_suggestion_parses() {
        let dialect = dialect();

        for suggestion in dialect.type_suggestions() {
            assert!(dialect.parse_type(suggestion).is_ok(), "{suggestion}");
        }
        assert!(dialect.parse_type(dialect.default_column_type()).is_ok());
    }

    fn released(major: u32) -> PgDialect {
        PgDialect::new(&ServerInfo::new("PostgreSQL", format!("{major}.0"), major, 0, 0))
    }

    fn orders() -> TableRef {
        TableRef::new(Some("app".to_owned()), "orders")
    }

    fn create(draft: DatabaseDraft) -> Vec<String> {
        sql(dialect().plan_create_database(&draft))
    }

    fn refused_option(plan: Result<DdlPlan, BuildDdlError>) -> Option<CatalogOption> {
        match plan {
            Err(BuildDdlError::InvalidOption { option, .. }) => Some(option),
            _ => None,
        }
    }

    #[test]
    fn a_truncate_restarts_identity_before_it_cascades() {
        let truncate = |cascade, restart_identity| {
            let options = TruncateTableOptions {
                cascade,
                restart_identity,
                cluster: None,
            };
            dialect().plan_truncate_table(&orders(), &options)
        };

        assert_eq!(sql(truncate(false, false)), ["TRUNCATE TABLE \"app\".\"orders\""]);
        assert_eq!(
            sql(truncate(true, false)),
            ["TRUNCATE TABLE \"app\".\"orders\" CASCADE"]
        );
        assert_eq!(
            sql(truncate(false, true)),
            ["TRUNCATE TABLE \"app\".\"orders\" RESTART IDENTITY"]
        );
        assert_eq!(
            sql(truncate(true, true)),
            ["TRUNCATE TABLE \"app\".\"orders\" RESTART IDENTITY CASCADE"]
        );
        assert_eq!(
            truncate(false, false).map(|plan| plan.kind),
            Ok(WriteKind::SchemaChanges)
        );
        let on_cluster = TruncateTableOptions {
            cluster: Some("main".to_owned()),
            ..TruncateTableOptions::default()
        };
        assert_eq!(
            dialect().plan_truncate_table(&orders(), &on_cluster),
            Err(BuildDdlError::Unsupported(DdlOperation::OnCluster))
        );
    }

    #[test]
    fn a_schema_is_created_with_its_owner_and_dropped_with_what_it_holds() {
        let owned = SchemaDraft {
            name: "sa\"les".to_owned(),
            owner: Some("ann".to_owned()),
        };
        let plain = SchemaDraft {
            name: "sales".to_owned(),
            owner: None,
        };

        assert_eq!(
            sql(dialect().plan_create_schema(&owned)),
            ["CREATE SCHEMA \"sa\"\"les\" AUTHORIZATION \"ann\""]
        );
        assert_eq!(sql(dialect().plan_create_schema(&plain)), ["CREATE SCHEMA \"sales\""]);
        assert_eq!(
            sql(dialect().plan_drop_schema("sales", DropSchemaOptions { cascade: true })),
            ["DROP SCHEMA \"sales\" CASCADE"]
        );
        assert_eq!(
            sql(dialect().plan_drop_schema("sales", DropSchemaOptions::default())),
            ["DROP SCHEMA \"sales\""]
        );
    }

    #[test]
    fn a_new_database_writes_only_the_options_set_in_the_servers_order() {
        let every = DatabaseDraft {
            owner: Some("ann".to_owned()),
            template: Some("tpl\"x".to_owned()),
            encoding: Some("LATIN1".to_owned()),
            locale: Some("de_DE.ISO8859-1".to_owned()),
            ..DatabaseDraft::named("shop")
        };
        let owned = DatabaseDraft {
            owner: Some("ann".to_owned()),
            ..DatabaseDraft::named("shop")
        };
        let copied = DatabaseDraft {
            template: Some("tpl".to_owned()),
            ..DatabaseDraft::named("shop")
        };

        assert_eq!(create(DatabaseDraft::named("sh\"op")), ["CREATE DATABASE \"sh\"\"op\""]);
        assert_eq!(create(owned), ["CREATE DATABASE \"shop\" OWNER \"ann\""]);
        assert_eq!(create(copied), ["CREATE DATABASE \"shop\" TEMPLATE \"tpl\""]);
        assert_eq!(
            create(every),
            ["CREATE DATABASE \"shop\" OWNER \"ann\" TEMPLATE \"tpl\"\"x\" ENCODING 'LATIN1' LOCALE 'de_DE.ISO8859-1'"]
        );
        let plan = dialect().plan_create_database(&DatabaseDraft::named("shop"));
        assert_eq!(plan.map(|plan| plan.kind), Ok(WriteKind::DatabaseChanges));
    }

    /// template1 takes only its own encoding and locale, so either one
    /// set without a template copies template0. A template the user chose
    /// stays, and the server answers for it.
    #[test]
    fn an_encoding_or_locale_without_a_template_copies_template0() {
        let encoded = DatabaseDraft {
            encoding: Some("UTF8".to_owned()),
            ..DatabaseDraft::named("shop")
        };
        let localised = DatabaseDraft {
            locale: Some("C".to_owned()),
            ..DatabaseDraft::named("shop")
        };
        let chosen = DatabaseDraft {
            template: Some("template1".to_owned()),
            ..encoded.clone()
        };

        assert_eq!(
            create(encoded),
            ["CREATE DATABASE \"shop\" TEMPLATE template0 ENCODING 'UTF8'"]
        );
        assert_eq!(
            create(localised.clone()),
            ["CREATE DATABASE \"shop\" TEMPLATE template0 LOCALE 'C'"]
        );
        assert_eq!(
            create(chosen),
            ["CREATE DATABASE \"shop\" TEMPLATE \"template1\" ENCODING 'UTF8'"]
        );
        assert_eq!(
            sql(released(12).plan_create_database(&localised)),
            ["CREATE DATABASE \"shop\" TEMPLATE template0 LC_COLLATE 'C' LC_CTYPE 'C'"]
        );
    }

    #[test]
    fn an_encoding_or_locale_that_could_leave_its_string_is_refused() {
        let encoded = |encoding: &str| DatabaseDraft {
            encoding: Some(encoding.to_owned()),
            ..DatabaseDraft::named("shop")
        };
        let localised = |locale: &str| DatabaseDraft {
            locale: Some(locale.to_owned()),
            ..DatabaseDraft::named("shop")
        };

        assert_eq!(
            create(encoded("UTF-8")),
            ["CREATE DATABASE \"shop\" TEMPLATE template0 ENCODING 'UTF-8'"]
        );
        for encoding in ["", "UTF8'; DROP DATABASE prod; --", "UTF 8"] {
            assert_eq!(
                refused_option(dialect().plan_create_database(&encoded(encoding))),
                Some(CatalogOption::Encoding),
                "{encoding:?}"
            );
        }
        assert_eq!(
            create(localised("it's")),
            ["CREATE DATABASE \"shop\" TEMPLATE template0 LOCALE 'it''s'"]
        );
        for locale in ["", "  ", "C\0"] {
            assert_eq!(
                refused_option(dialect().plan_create_database(&localised(locale))),
                Some(CatalogOption::Locale),
                "{locale:?}"
            );
        }
        let empty_owner = DatabaseDraft {
            owner: Some(String::new()),
            ..DatabaseDraft::named("shop")
        };
        assert_eq!(
            refused_option(dialect().plan_create_database(&empty_owner)),
            Some(CatalogOption::Owner)
        );
    }

    #[test]
    fn a_name_past_63_bytes_is_refused_before_the_server_cuts_it_short() {
        let longest = "a".repeat(63);
        let schema = |name: &str| SchemaDraft {
            name: name.to_owned(),
            owner: None,
        };

        assert!(dialect().plan_create_database(&DatabaseDraft::named(&longest)).is_ok());
        assert!(dialect().plan_create_schema(&schema(longest.as_str())).is_ok());
        for name in ["a".repeat(64), "é".repeat(32)] {
            assert_eq!(
                refused_option(dialect().plan_create_database(&DatabaseDraft::named(&name))),
                Some(CatalogOption::Name),
                "{name}"
            );
            assert_eq!(
                refused_option(dialect().plan_create_schema(&schema(name.as_str()))),
                Some(CatalogOption::Name),
                "{name}"
            );
        }
        assert_eq!(dialect().catalog_capabilities().name_limit, Some(NameLimit::Bytes(63)));
    }

    #[test]
    fn a_drop_closes_the_other_sessions_only_from_13() {
        let forced = DropDatabaseOptions {
            force: true,
            cluster: None,
        };
        let plain = DropDatabaseOptions::default();

        assert_eq!(
            sql(released(13).plan_drop_database("sh\"op", &forced)),
            ["DROP DATABASE \"sh\"\"op\" WITH (FORCE)"]
        );
        assert_eq!(
            sql(released(13).plan_drop_database("shop", &plain)),
            ["DROP DATABASE \"shop\""]
        );
        assert_eq!(
            sql(released(12).plan_drop_database("shop", &plain)),
            ["DROP DATABASE \"shop\""]
        );
        assert_eq!(
            released(12).plan_drop_database("shop", &forced),
            Err(BuildDdlError::Unsupported(DdlOperation::DropDatabaseForce))
        );
        assert!(released(13).catalog_capabilities().drop_database_force);
        assert!(!released(12).catalog_capabilities().drop_database_force);
        let plan = released(18).plan_drop_database("shop", &forced);
        assert_eq!(plan.map(|plan| plan.kind), Ok(WriteKind::DatabaseChanges));
    }

    #[test]
    fn templates_and_system_schemas_are_withheld_from_a_drop() {
        let dialect = dialect();

        for database in ["template0", "template1"] {
            assert!(protects_database(&dialect, database), "{database}");
        }
        for database in ["postgres", "shop", "Template1"] {
            assert!(!protects_database(&dialect, database), "{database}");
        }
        for schema in ["pg_catalog", "pg_toast", "pg_temp_3", "information_schema"] {
            assert!(protects_schema(&dialect, schema), "{schema}");
        }
        for schema in ["public", "sales", "PG_sales"] {
            assert!(!protects_schema(&dialect, schema), "{schema}");
        }
    }

    /// The menu offers what the capabilities say, so each one has to plan.
    #[test]
    fn every_catalog_operation_offered_plans() {
        for major in [12, 13, 18] {
            let dialect = released(major);
            let offered = catalog_capabilities(&dialect);
            let fields = offered.database_fields;
            let set = |on: bool, value: &str| on.then(|| value.to_owned());
            let truncate = TruncateTableOptions {
                cascade: offered.truncate_cascade,
                restart_identity: offered.truncate_restart_identity,
                cluster: set(offered.on_cluster, "main"),
            };
            let schema = SchemaDraft {
                name: "sales".to_owned(),
                owner: set(offered.schema_owner, "ann"),
            };
            let database = DatabaseDraft {
                owner: set(fields.owner, "ann"),
                template: set(fields.template, "template0"),
                encoding: set(fields.encoding, "UTF8"),
                locale: set(fields.locale, "C"),
                character_set: set(fields.character_set, "utf8mb4"),
                collation: set(fields.collation, "C"),
                cluster: set(offered.on_cluster, "main"),
                replication: fields.replication.then_some(KeyspaceReplication::Simple { factor: 1 }),
                tablets: fields.tablets.then_some(true),
                first_collection: set(fields.first_collection, "orders"),
                ..DatabaseDraft::named("shop")
            };
            let cascade = DropSchemaOptions {
                cascade: offered.drop_schema_cascade,
            };
            let drop = DropDatabaseOptions {
                force: offered.drop_database_force,
                cluster: set(offered.on_cluster, "main"),
            };

            let truncated = plan_truncate_table(&dialect, &orders(), &truncate);
            let created_schema = plan_create_schema(&dialect, &schema);
            let dropped_schema = plan_drop_schema(&dialect, "sales", cascade);
            let created = plan_create_database(&dialect, &database);
            let dropped = plan_drop_database(&dialect, "shop", &drop);

            assert_eq!(truncated.is_ok(), offered.truncate_table, "{major}: {truncated:?}");
            assert_eq!(
                created_schema.is_ok(),
                offered.create_schema,
                "{major}: {created_schema:?}"
            );
            assert_eq!(
                dropped_schema.is_ok(),
                offered.drop_schema,
                "{major}: {dropped_schema:?}"
            );
            assert_eq!(created.is_ok(), offered.create_database, "{major}: {created:?}");
            assert_eq!(dropped.is_ok(), offered.drop_database, "{major}: {dropped:?}");
        }
        let offered = released(18).catalog_capabilities();
        assert!(offered.truncate_table && offered.truncate_cascade && offered.truncate_restart_identity);
        assert!(offered.create_schema && offered.drop_schema && offered.drop_schema_cascade && offered.schema_owner);
        assert!(offered.create_database && offered.drop_database && offered.drop_database_force);
        assert!(!offered.truncate_refused_when_referenced && !offered.on_cluster);
        assert_eq!(
            offered.database_fields,
            DatabaseFields {
                owner: true,
                template: true,
                encoding: true,
                locale: true,
                ..DatabaseFields::default()
            }
        );
    }
}
