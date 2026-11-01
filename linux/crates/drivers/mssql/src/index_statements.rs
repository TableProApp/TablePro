use std::collections::HashMap;

use tablepro_core::ddl::ddl_sql::index_keys_sql;
use tablepro_core::meta::IndexInfo;
use tablepro_core::{DriverError, Value};

use crate::catalog::Cells;
use crate::dialect::{MssqlDialect, quote};
use crate::in_band_request::{Interrupt, Watch};
use crate::physical::MssqlClient;
use crate::workspace_call::{catalogue_rows, text_param};

// A constraint's index has no CREATE INDEX of its own; XML, spatial and columnstore indexes take
// syntax this does not write.
fn index_options_sql(major_version: u32) -> String {
    // OPTIMIZE_FOR_SEQUENTIAL_KEY came with SQL Server 2019.
    let sequential = match major_version >= 15 {
        true => "CAST(i.optimize_for_sequential_key AS int)",
        false => "0",
    };
    format!(
        "SELECT i.name, i.type_desc, CAST(i.is_unique AS int), i.filter_definition, i.fill_factor, \
                CAST(i.is_padded AS int), CAST(i.ignore_dup_key AS int), CAST(s.no_recompute AS int), \
                CAST(s.is_incremental AS int), CAST(i.allow_row_locks AS int), CAST(i.allow_page_locks AS int), \
                {sequential}, CAST(i.is_disabled AS int), ds.name, RTRIM(ds.type) \
         FROM sys.indexes i \
         JOIN sys.stats s ON s.object_id = i.object_id AND s.stats_id = i.index_id \
         JOIN sys.data_spaces ds ON ds.data_space_id = i.data_space_id \
         WHERE i.object_id = OBJECT_ID(@P1) AND i.type IN (1, 2) AND i.is_primary_key = 0 \
               AND i.is_unique_constraint = 0 AND i.is_hypothetical = 0"
    )
}

// An aligned index lists its partition column as neither key nor included.
const INDEX_COLUMNS_SQL: &str = "SELECT i.name, c.name, CAST(ic.is_included_column AS int), ic.partition_ordinal \
    FROM sys.indexes i \
    JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id \
    JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id \
    WHERE i.object_id = OBJECT_ID(@P1) AND i.type IN (1, 2) \
          AND (ic.is_included_column = 1 OR ic.partition_ordinal = 1) \
    ORDER BY i.index_id, ic.index_column_id";

// A disabled index has no partitions, so its compression is not known.
const INDEX_PARTITIONS_SQL: &str = "SELECT i.name, p.partition_number, p.data_compression_desc \
    FROM sys.indexes i \
    JOIN sys.partitions p ON p.object_id = i.object_id AND p.index_id = i.index_id \
    WHERE i.object_id = OBJECT_ID(@P1) AND i.type IN (1, 2) \
    ORDER BY i.index_id, p.partition_number";

pub(crate) async fn fetch_index_statements(
    client: &mut MssqlClient,
    watch: &Watch,
    relation: &str,
    major_version: u32,
    indexes: &mut [IndexInfo],
) -> Result<(), Interrupt> {
    let params = [text_param(relation)];
    let options = catalogue_rows(client, watch, &index_options_sql(major_version), &params).await?;
    let columns = catalogue_rows(client, watch, INDEX_COLUMNS_SQL, &params).await?;
    let partitions = catalogue_rows(client, watch, INDEX_PARTITIONS_SQL, &params).await?;
    let rows = CatalogRows {
        options: &options,
        columns: &columns,
        partitions: &partitions,
    };
    let mut statements = statements(&MssqlDialect::new(major_version), relation, indexes, &rows)?;
    for index in indexes {
        index.definition = statements.remove(&index.name);
    }
    Ok(())
}

// CREATE INDEX has no way to say disabled, so a disabled index's statement ends with this one.
pub(crate) fn disabling(name: &str, relation: &str) -> String {
    format!("ALTER INDEX {} ON {relation} DISABLE", quote(name))
}

struct CatalogRows<'a> {
    options: &'a [Vec<Value>],
    columns: &'a [Vec<Value>],
    partitions: &'a [Vec<Value>],
}

#[derive(Default)]
struct IndexParts {
    included: Vec<String>,
    partitioned_by: Option<String>,
    compression: Vec<(i64, String)>,
}

fn statements(
    dialect: &MssqlDialect,
    relation: &str,
    indexes: &[IndexInfo],
    rows: &CatalogRows<'_>,
) -> Result<HashMap<String, String>, DriverError> {
    let mut parts: HashMap<String, IndexParts> = HashMap::new();
    for row in rows.columns {
        let cells = Cells::new(row, "sys.index_columns");
        let entry = parts.entry(cells.required_text(0)?).or_default();
        let column = cells.required_text(1)?;
        if cells.int(3) == Some(1) {
            entry.partitioned_by = Some(column.clone());
        }
        if cells.flag(2) {
            entry.included.push(column);
        }
    }
    for row in rows.partitions {
        let cells = Cells::new(row, "sys.partitions");
        let entry = parts.entry(cells.required_text(0)?).or_default();
        let number = cells.int(1).unwrap_or_default();
        entry.compression.push((number, cells.required_text(2)?));
    }
    let mut statements = HashMap::new();
    for row in rows.options {
        let cells = Cells::new(row, "sys.indexes");
        let name = cells.required_text(0)?;
        let Some(index) = indexes.iter().find(|index| index.name == name) else {
            continue;
        };
        let parts = parts.remove(&name).unwrap_or_default();
        statements.insert(name, statement(dialect, relation, index, &cells, &parts)?);
    }
    Ok(statements)
}

// SQL Server keeps no text for an index. Storage counts: a clustered index made again without its
// partition scheme moves the whole table off it.
fn statement(
    dialect: &MssqlDialect,
    relation: &str,
    index: &IndexInfo,
    cells: &Cells<'_>,
    parts: &IndexParts,
) -> Result<String, DriverError> {
    let unique = if cells.flag(2) { "UNIQUE " } else { "" };
    let mut sql = format!(
        "CREATE {unique}{} INDEX {} ON {relation} ({})",
        cells.required_text(1)?,
        quote(&index.name),
        index_keys_sql(dialect, index)
    );
    if !parts.included.is_empty() {
        let included: Vec<String> = parts.included.iter().map(|column| quote(column)).collect();
        sql.push_str(&format!(" INCLUDE ({})", included.join(", ")));
    }
    if let Some(filter) = cells.text(3) {
        sql.push_str(&format!(" WHERE {filter}"));
    }
    let mut options = with_options(cells);
    options.extend(compression(&parts.compression));
    if !options.is_empty() {
        sql.push_str(&format!(" WITH ({})", options.join(", ")));
    }
    let space = quote(&cells.required_text(13)?);
    match (cells.text(14).as_deref(), &parts.partitioned_by) {
        (Some("PS"), Some(column)) => sql.push_str(&format!(" ON {space}({})", quote(column))),
        _ => sql.push_str(&format!(" ON {space}")),
    }
    if cells.flag(12) {
        sql.push_str(&format!(";\n\n{}", disabling(&index.name, relation)));
    }
    Ok(sql)
}

// Only what differs from CREATE INDEX's defaults, in the order the documentation lists them.
fn with_options(cells: &Cells<'_>) -> Vec<String> {
    let mut options = Vec::new();
    if cells.flag(5) {
        options.push("PAD_INDEX = ON".to_owned());
    }
    if let Some(fill) = cells.int(4).filter(|fill| *fill > 0) {
        options.push(format!("FILLFACTOR = {fill}"));
    }
    for (column, on, option) in [
        (6, true, "IGNORE_DUP_KEY"),
        (7, true, "STATISTICS_NORECOMPUTE"),
        (8, true, "STATISTICS_INCREMENTAL"),
        (9, false, "ALLOW_ROW_LOCKS"),
        (10, false, "ALLOW_PAGE_LOCKS"),
        (11, true, "OPTIMIZE_FOR_SEQUENTIAL_KEY"),
    ] {
        if cells.flag(column) == on {
            options.push(format!("{option} = {}", if on { "ON" } else { "OFF" }));
        }
    }
    options
}

// One setting covers an index whose partitions agree; ON PARTITIONS names the rest.
fn compression(partitions: &[(i64, String)]) -> Vec<String> {
    let mut kinds: Vec<&str> = Vec::new();
    for (_, kind) in partitions {
        if !kinds.contains(&kind.as_str()) {
            kinds.push(kind);
        }
    }
    match kinds.as_slice() {
        [] | ["NONE"] => Vec::new(),
        [kind] => vec![format!("DATA_COMPRESSION = {kind}")],
        _ => kinds
            .iter()
            .filter(|kind| **kind != "NONE")
            .map(|kind| {
                let numbers: Vec<String> = partitions
                    .iter()
                    .filter(|(_, other)| other == kind)
                    .map(|(number, _)| number.to_string())
                    .collect();
                format!("DATA_COMPRESSION = {kind} ON PARTITIONS ({})", numbers.join(", "))
            })
            .collect(),
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::IndexKey;

    use super::*;

    fn text(value: &str) -> Value {
        Value::Text(value.to_owned())
    }

    fn index(name: &str, keys: &[(&str, bool)]) -> IndexInfo {
        IndexInfo {
            name: name.to_owned(),
            keys: keys
                .iter()
                .map(|(column, descending)| IndexKey::Column {
                    name: (*column).to_owned(),
                    descending: *descending,
                })
                .collect(),
            unique: false,
            primary: false,
            predicate: None,
            definition: None,
        }
    }

    struct Facts {
        kind: &'static str,
        unique: bool,
        filter: Option<&'static str>,
        flags: [i64; 9],
        space: (&'static str, &'static str),
    }

    const PLAIN: Facts = Facts {
        kind: "NONCLUSTERED",
        unique: false,
        filter: None,
        // fill, pad, ignore_dup_key, no_recompute, incremental, row locks, page locks, sequential, disabled
        flags: [0, 0, 0, 0, 0, 1, 1, 0, 0],
        space: ("PRIMARY", "FG"),
    };

    fn row(name: &str, facts: Facts) -> Vec<Value> {
        let mut row = vec![
            text(name),
            text(facts.kind),
            Value::Int(i64::from(facts.unique)),
            facts.filter.map_or(Value::Null, text),
        ];
        row.extend(facts.flags.iter().map(|flag| Value::Int(*flag)));
        row.extend([text(facts.space.0), text(facts.space.1)]);
        row
    }

    fn partition_rows(index: &str, kinds: &[&str]) -> Vec<Vec<Value>> {
        (1..)
            .zip(kinds)
            .map(|(number, kind)| vec![text(index), Value::Int(number), text(kind)])
            .collect()
    }

    fn column(index: &str, name: &str, included: bool, partition: i64) -> Vec<Value> {
        vec![
            text(index),
            text(name),
            Value::Int(i64::from(included)),
            Value::Int(partition),
        ]
    }

    #[test]
    fn each_index_is_written_with_its_storage_and_options() {
        let indexes = [
            index("cx_pt", &[("k", false)]),
            index("ix_filt", &[("a", true), ("c", false)]),
            index("ux_opts", &[("c", false), ("d", false)]),
            index("ix_ppc", &[("a", false)]),
            index("ix_dis", &[("e", false)]),
            index("we]ird", &[("f", false)]),
        ];
        let options = [
            row(
                "cx_pt",
                Facts {
                    kind: "CLUSTERED",
                    space: ("ps", "PS"),
                    ..PLAIN
                },
            ),
            row(
                "ix_filt",
                Facts {
                    filter: Some("([a]>(0) AND [b]<>N'x''y')"),
                    ..PLAIN
                },
            ),
            row(
                "ux_opts",
                Facts {
                    unique: true,
                    flags: [80, 1, 1, 1, 0, 1, 0, 1, 0],
                    ..PLAIN
                },
            ),
            row(
                "ix_ppc",
                Facts {
                    flags: [0, 0, 0, 0, 1, 1, 1, 0, 0],
                    space: ("ps", "PS"),
                    ..PLAIN
                },
            ),
            row(
                "ix_dis",
                Facts {
                    flags: [0, 0, 0, 0, 0, 1, 1, 0, 1],
                    ..PLAIN
                },
            ),
            row(
                "we]ird",
                Facts {
                    flags: [0, 0, 0, 0, 0, 0, 1, 0, 0],
                    space: ("fg2", "FG"),
                    ..PLAIN
                },
            ),
        ];
        let columns = [
            column("cx_pt", "k", false, 1),
            column("ix_filt", "b", true, 0),
            column("ix_ppc", "k", false, 1),
        ];

        let partitions = [
            partition_rows("cx_pt", &["NONE", "NONE", "NONE"]),
            partition_rows("ix_filt", &["NONE"]),
            partition_rows("ux_opts", &["PAGE"]),
            partition_rows("ix_ppc", &["PAGE", "NONE", "ROW"]),
            partition_rows("we]ird", &["NONE"]),
        ]
        .concat();
        let rows = CatalogRows {
            options: &options,
            columns: &columns,
            partitions: &partitions,
        };

        let mut statements = statements(&MssqlDialect::new(16), "[dbo].[t]", &indexes, &rows).expect("the statements");
        let mut statement = |name: &str| statements.remove(name).expect(name);

        assert_eq!(
            statement("cx_pt"),
            "CREATE CLUSTERED INDEX [cx_pt] ON [dbo].[t] ([k]) ON [ps]([k])"
        );
        assert_eq!(
            statement("ix_filt"),
            "CREATE NONCLUSTERED INDEX [ix_filt] ON [dbo].[t] ([a] DESC, [c]) INCLUDE ([b]) \
             WHERE ([a]>(0) AND [b]<>N'x''y') ON [PRIMARY]"
        );
        assert_eq!(
            statement("ux_opts"),
            "CREATE UNIQUE NONCLUSTERED INDEX [ux_opts] ON [dbo].[t] ([c], [d]) WITH (PAD_INDEX = ON, \
             FILLFACTOR = 80, IGNORE_DUP_KEY = ON, STATISTICS_NORECOMPUTE = ON, ALLOW_PAGE_LOCKS = OFF, \
             OPTIMIZE_FOR_SEQUENTIAL_KEY = ON, DATA_COMPRESSION = PAGE) ON [PRIMARY]"
        );
        assert_eq!(
            statement("ix_ppc"),
            "CREATE NONCLUSTERED INDEX [ix_ppc] ON [dbo].[t] ([a]) WITH (STATISTICS_INCREMENTAL = ON, \
             DATA_COMPRESSION = PAGE ON PARTITIONS (1), DATA_COMPRESSION = ROW ON PARTITIONS (3)) ON [ps]([k])"
        );
        assert_eq!(
            statement("ix_dis"),
            "CREATE NONCLUSTERED INDEX [ix_dis] ON [dbo].[t] ([e]) ON [PRIMARY];\n\n\
             ALTER INDEX [ix_dis] ON [dbo].[t] DISABLE"
        );
        assert_eq!(
            statement("we]ird"),
            "CREATE NONCLUSTERED INDEX [we]]ird] ON [dbo].[t] ([f]) WITH (ALLOW_ROW_LOCKS = OFF) ON [fg2]"
        );
    }

    #[test]
    fn an_index_the_options_do_not_list_has_no_statement() {
        let indexes = [index("pk", &[("id", false)])];

        let rows = CatalogRows {
            options: &[],
            columns: &[],
            partitions: &[],
        };

        let statements = statements(&MssqlDialect::new(14), "[dbo].[t]", &indexes, &rows).expect("the statements");

        assert!(statements.is_empty());
    }

    #[test]
    fn sql_server_2017_reads_no_sequential_key_flag() {
        assert!(!index_options_sql(14).contains("optimize_for_sequential_key"));
        assert!(index_options_sql(15).contains("i.optimize_for_sequential_key"));
    }
}
