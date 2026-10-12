use tablepro_core::column::{
    BoolStorage, CatalogType, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, SqlTypeExpr,
    TemporalZone, TextLength, TimeRange,
};

/// How long a character or binary type is declared.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Length {
    Unspecified,
    Max,
    /// Characters for character types, bytes for binary ones.
    Of(u32),
}

/// A SQL Server type, from the catalogue or from text the user typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SqlServerType {
    /// The system type values are stored as, in lower case.
    base: String,
    length: Length,
    precision: Option<u32>,
    scale: Option<u32>,
    /// The name of an alias type or a CLR type, as DDL has to restate it.
    alias: Option<String>,
    /// A type the driver cannot see into: a CLR type nobody ships with
    /// the server, or an alias typed by name. It is read as the server's
    /// text.
    opaque: bool,
}

/// What the app makes of a type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Classified {
    pub(crate) kind: ColumnKind,
    pub(crate) read_form: ReadForm,
    /// rowversion: the server writes it on every change, nobody else may.
    pub(crate) server_written: bool,
}

/// The character types whose catalogue length is in bytes, two to a
/// character.
const NATIONAL: [&str; 2] = ["nchar", "nvarchar"];

const SYSTEM_TYPES: [&str; 34] = [
    "bigint",
    "binary",
    "bit",
    "char",
    "date",
    "datetime",
    "datetime2",
    "datetimeoffset",
    "decimal",
    "float",
    "geography",
    "geometry",
    "hierarchyid",
    "image",
    "int",
    "money",
    "nchar",
    "ntext",
    "numeric",
    "nvarchar",
    "real",
    "rowversion",
    "smalldatetime",
    "smallint",
    "smallmoney",
    "sql_variant",
    "sysname",
    "text",
    "time",
    "timestamp",
    "tinyint",
    "uniqueidentifier",
    "varbinary",
    "varchar",
];

impl SqlServerType {
    /// A column as `sys.columns` and `sys.types` describe it. Lengths are
    /// in bytes there, `-1` meaning max; precision and scale are set for
    /// every type and mean something only for some.
    pub(crate) fn from_catalog(facts: CatalogFacts<'_>) -> Self {
        let base = facts.base_type.to_ascii_lowercase();
        let length = match facts.max_length {
            -1 => Length::Max,
            bytes if NATIONAL.contains(&base.as_str()) => Length::Of(u32::try_from(bytes / 2).unwrap_or(0)),
            bytes => Length::Of(u32::try_from(bytes).unwrap_or(0)),
        };
        let alias = (facts.user_clr || facts.alias).then(|| match facts.type_schema {
            Some(schema) if facts.user_defined => format!("{}.{}", bracket(schema), bracket(facts.type_name)),
            _ => facts.type_name.to_owned(),
        });
        Self {
            base,
            length,
            precision: u32::try_from(facts.precision).ok(),
            scale: u32::try_from(facts.scale).ok(),
            alias,
            opaque: facts.user_clr,
        }
    }

    /// A type the user typed, which the engine's own parser has already
    /// accepted. A name that is not a system type is an alias or a CLR
    /// type the driver cannot see into.
    pub(crate) fn parse(text: &str) -> Self {
        let text = text.trim();
        let (name, arguments) = match text.find('(') {
            Some(open) => {
                let inside = text.get(open + 1..).unwrap_or_default();
                let inside = inside.strip_suffix(')').unwrap_or(inside);
                (text.get(..open).unwrap_or_default().trim(), Some(inside))
            }
            None => (text, None),
        };
        let unquoted = name.trim_start_matches('[').trim_end_matches(']').to_ascii_lowercase();
        let base = match unquoted.as_str() {
            "double precision" => "float".to_owned(),
            "character" => "char".to_owned(),
            "character varying" => "varchar".to_owned(),
            other => other.to_owned(),
        };
        if !SYSTEM_TYPES.contains(&base.as_str()) {
            return Self {
                base,
                length: Length::Unspecified,
                precision: None,
                scale: None,
                alias: Some(text.to_owned()),
                opaque: true,
            };
        }
        let arguments: Vec<&str> = arguments
            .map(|inside| inside.split(',').map(str::trim).collect())
            .unwrap_or_default();
        let number = |index: usize| arguments.get(index).and_then(|argument| argument.parse::<u32>().ok());
        let length = match arguments.first() {
            Some(first) if first.eq_ignore_ascii_case("max") => Length::Max,
            Some(_) => number(0).map_or(Length::Unspecified, Length::Of),
            None => Length::Unspecified,
        };
        let (precision, scale) = match base.as_str() {
            "decimal" | "numeric" => (number(0).or(Some(18)), number(1).or(Some(0))),
            "float" => (number(0).or(Some(53)), None),
            "time" | "datetime2" | "datetimeoffset" => (None, number(0).or(Some(7))),
            _ => (None, None),
        };
        Self {
            base,
            length,
            precision,
            scale,
            alias: None,
            opaque: false,
        }
    }

    /// The type as DDL spells it, modifiers included.
    pub(crate) fn declaration(&self) -> String {
        if let Some(alias) = &self.alias {
            return alias.clone();
        }
        let base = &self.base;
        match base.as_str() {
            "char" | "varchar" | "nchar" | "nvarchar" | "binary" | "varbinary" => match self.length {
                Length::Max => format!("{base}(max)"),
                Length::Of(length) => format!("{base}({length})"),
                Length::Unspecified => base.clone(),
            },
            "decimal" | "numeric" => match (self.precision, self.scale) {
                (Some(precision), Some(scale)) => format!("{base}({precision},{scale})"),
                _ => base.clone(),
            },
            "float" => match self.precision {
                Some(precision) if precision != 53 => format!("float({precision})"),
                _ => base.clone(),
            },
            "time" | "datetime2" | "datetimeoffset" => match self.scale {
                Some(scale) => format!("{base}({scale})"),
                None => base.clone(),
            },
            _ => base.clone(),
        }
    }

    /// The type a bound text parameter is cast to. A length would
    /// truncate silently, so text casts to its max form, while a decimal
    /// keeps its digits because a bare `decimal` means `decimal(18,0)`.
    pub(crate) fn cast_target(&self) -> String {
        if self.alias.is_some() {
            return self.declaration();
        }
        match self.base.as_str() {
            "char" | "varchar" | "text" => "varchar(max)".to_owned(),
            "nchar" | "nvarchar" | "ntext" | "sysname" => "nvarchar(max)".to_owned(),
            "binary" | "varbinary" | "image" => "varbinary(max)".to_owned(),
            _ => self.declaration(),
        }
    }

    pub(crate) fn classify(&self) -> Classified {
        let native = |kind| Classified {
            kind,
            read_form: ReadForm::Native,
            server_written: false,
        };
        let as_text = |kind| Classified {
            kind,
            read_form: ReadForm::ServerText,
            server_written: false,
        };
        if self.opaque {
            return as_text(ColumnKind::Other);
        }
        let integer = |width, signed| native(ColumnKind::Integer(IntegerKind { width, signed }));
        let fractional = self.scale.and_then(|scale| u8::try_from(scale).ok());
        match self.base.as_str() {
            "bit" => native(ColumnKind::Bool(BoolStorage::Native)),
            "tinyint" => integer(IntegerWidth::W8, false),
            "smallint" => integer(IntegerWidth::W16, true),
            "int" => integer(IntegerWidth::W32, true),
            "bigint" => integer(IntegerWidth::W64, true),
            "real" => native(ColumnKind::Float(FloatWidth::F32)),
            "float" => native(ColumnKind::Float(match self.precision {
                Some(precision) if precision <= 24 => FloatWidth::F32,
                _ => FloatWidth::F64,
            })),
            "decimal" | "numeric" => native(ColumnKind::Decimal {
                precision: self.precision,
                scale: self.scale,
            }),
            // tiberius reads MONEY as a float, so browse asks for it as a
            // decimal of the same scale instead.
            "money" | "smallmoney" => Classified {
                kind: ColumnKind::Money { scale: Some(4) },
                read_form: ReadForm::ServerNumeric,
                server_written: false,
            },
            "char" | "nchar" => native(ColumnKind::Text {
                length: self.text_length(TextLength::Fixed),
            }),
            "varchar" | "nvarchar" | "sysname" => native(ColumnKind::Text {
                length: self.text_length(TextLength::Varying),
            }),
            "text" | "ntext" => native(ColumnKind::Text {
                length: TextLength::Unbounded,
            }),
            "binary" => native(ColumnKind::Bytes {
                length: self.text_length(TextLength::Fixed),
            }),
            "varbinary" => native(ColumnKind::Bytes {
                length: self.text_length(TextLength::Varying),
            }),
            "image" => native(ColumnKind::Bytes {
                length: TextLength::Unbounded,
            }),
            "timestamp" | "rowversion" => Classified {
                kind: ColumnKind::Bytes {
                    length: TextLength::Fixed(8),
                },
                read_form: ReadForm::Native,
                server_written: true,
            },
            "uniqueidentifier" => native(ColumnKind::Uuid),
            "date" => native(ColumnKind::Date),
            "time" => native(ColumnKind::Time {
                fractional_digits: fractional,
                with_offset: false,
                range: TimeRange::TimeOfDay,
            }),
            "datetime" => native(ColumnKind::Timestamp {
                fractional_digits: Some(3),
                zone: TemporalZone::Naive,
            }),
            "smalldatetime" => native(ColumnKind::Timestamp {
                fractional_digits: Some(0),
                zone: TemporalZone::Naive,
            }),
            "datetime2" => native(ColumnKind::Timestamp {
                fractional_digits: fractional,
                zone: TemporalZone::Naive,
            }),
            "datetimeoffset" => native(ColumnKind::Timestamp {
                fractional_digits: fractional,
                zone: TemporalZone::Offset,
            }),
            "xml" => native(ColumnKind::Xml),
            // tiberius reads the stored value in its own base type.
            "sql_variant" => native(ColumnKind::Variant),
            "geography" | "geometry" => as_text(ColumnKind::Spatial),
            _ => as_text(ColumnKind::Other),
        }
    }

    fn text_length(&self, declared: fn(u32) -> TextLength) -> TextLength {
        match self.length {
            Length::Of(length) => declared(length),
            Length::Max | Length::Unspecified => TextLength::Unbounded,
        }
    }

    /// The column type the app works with.
    pub(crate) fn column_type(&self) -> (ColumnType, bool) {
        let classified = self.classify();
        let declaration = self.declaration();
        let column_type = ColumnType {
            name: declaration.clone(),
            kind: classified.kind,
            catalog: Some(CatalogType {
                declaration: SqlTypeExpr::from_catalog_text(declaration),
                cast_target: SqlTypeExpr::from_catalog_text(self.cast_target()),
            }),
            dynamic_storage: false,
            read_form: classified.read_form,
        };
        (column_type, classified.server_written)
    }
}

/// What the catalogue says about one column's type.
#[derive(Debug, Clone, Copy)]
pub(crate) struct CatalogFacts<'a> {
    pub(crate) type_name: &'a str,
    pub(crate) base_type: &'a str,
    pub(crate) type_schema: Option<&'a str>,
    pub(crate) user_defined: bool,
    /// An alias over a system type, `sysname` included.
    pub(crate) alias: bool,
    pub(crate) user_clr: bool,
    pub(crate) max_length: i64,
    pub(crate) precision: i64,
    pub(crate) scale: i64,
}

fn bracket(name: &str) -> String {
    format!("[{}]", name.replace(']', "]]"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn system(base: &str, max_length: i64, precision: i64, scale: i64) -> SqlServerType {
        SqlServerType::from_catalog(CatalogFacts {
            type_name: base,
            base_type: base,
            type_schema: Some("sys"),
            user_defined: false,
            alias: false,
            user_clr: false,
            max_length,
            precision,
            scale,
        })
    }

    #[test]
    fn format_type_lengths_and_precision() {
        assert_eq!(system("int", 4, 10, 0).declaration(), "int");
        assert_eq!(system("varchar", 255, 0, 0).declaration(), "varchar(255)");
        assert_eq!(system("varchar", -1, 0, 0).declaration(), "varchar(max)");
        assert_eq!(system("nvarchar", 510, 0, 0).declaration(), "nvarchar(255)");
        assert_eq!(system("nvarchar", -1, 0, 0).declaration(), "nvarchar(max)");
        assert_eq!(system("decimal", 9, 18, 2).declaration(), "decimal(18,2)");
        assert_eq!(system("datetime2", 8, 27, 3).declaration(), "datetime2(3)");
        assert_eq!(system("float", 8, 53, 0).declaration(), "float");
        assert_eq!(system("float", 4, 24, 0).declaration(), "float(24)");
    }

    #[test]
    fn mssql_money_hierarchyid_geography_alias() {
        let money = system("money", 8, 19, 4).classify();
        assert_eq!(money.kind, ColumnKind::Money { scale: Some(4) });
        assert_eq!(money.read_form, ReadForm::ServerNumeric);

        let hierarchy = system("hierarchyid", 892, 0, 0).classify();
        assert_eq!(hierarchy.kind, ColumnKind::Other);
        assert_eq!(hierarchy.read_form, ReadForm::ServerText);

        for spatial in ["geography", "geometry"] {
            let classified = system(spatial, -1, 0, 0).classify();
            assert_eq!(classified.kind, ColumnKind::Spatial);
            assert_eq!(classified.read_form, ReadForm::ServerText);
        }
        assert_eq!(system("sql_variant", 8016, 0, 0).classify().kind, ColumnKind::Variant);

        let phone = SqlServerType::from_catalog(CatalogFacts {
            type_name: "Phone",
            base_type: "nvarchar",
            type_schema: Some("dbo"),
            user_defined: true,
            alias: true,
            user_clr: false,
            max_length: 40,
            precision: 0,
            scale: 0,
        });
        assert_eq!(phone.declaration(), "[dbo].[Phone]");
        assert_eq!(
            phone.classify().kind,
            ColumnKind::Text {
                length: TextLength::Varying(20)
            }
        );
        let sysname = SqlServerType::from_catalog(CatalogFacts {
            type_name: "sysname",
            base_type: "nvarchar",
            type_schema: Some("sys"),
            user_defined: false,
            alias: true,
            user_clr: false,
            max_length: 256,
            precision: 0,
            scale: 0,
        });
        assert_eq!(sysname.declaration(), "sysname");
        assert_eq!(
            sysname.classify().kind,
            ColumnKind::Text {
                length: TextLength::Varying(128)
            }
        );
    }

    #[test]
    fn a_user_clr_type_is_other_read_as_text() {
        let clr = SqlServerType::from_catalog(CatalogFacts {
            type_name: "Point",
            base_type: "Point",
            type_schema: Some("geo"),
            user_defined: true,
            alias: false,
            user_clr: true,
            max_length: 64,
            precision: 0,
            scale: 0,
        });

        assert_eq!(clr.declaration(), "[geo].[Point]");
        assert_eq!(clr.cast_target(), "[geo].[Point]");
        assert_eq!(clr.classify().kind, ColumnKind::Other);
        assert_eq!(clr.classify().read_form, ReadForm::ServerText);
    }

    #[test]
    fn rowversion_is_written_by_the_server_alone() {
        let classified = system("timestamp", 8, 0, 0).classify();

        assert!(classified.server_written);
        assert_eq!(
            classified.kind,
            ColumnKind::Bytes {
                length: TextLength::Fixed(8)
            }
        );
    }

    #[test]
    fn a_typed_type_classifies_like_the_catalogue() {
        let cases = [
            ("nvarchar(255)", "nvarchar(255)"),
            ("NVARCHAR ( MAX )", "nvarchar(max)"),
            ("decimal(10, 2)", "decimal(10,2)"),
            ("decimal", "decimal(18,0)"),
            ("datetime2", "datetime2(7)"),
            ("[int]", "int"),
            ("double precision", "float"),
        ];
        for (typed, declared) in cases {
            assert_eq!(SqlServerType::parse(typed).declaration(), declared, "{typed}");
        }
        assert_eq!(
            SqlServerType::parse("varchar(40)").classify().kind,
            ColumnKind::Text {
                length: TextLength::Varying(40)
            }
        );
        let alias = SqlServerType::parse("dbo.Phone");
        assert_eq!(alias.declaration(), "dbo.Phone");
        assert_eq!(alias.classify().kind, ColumnKind::Other);
    }

    #[test]
    fn text_casts_to_its_max_form() {
        assert_eq!(system("varchar", 10, 0, 0).cast_target(), "varchar(max)");
        assert_eq!(system("nchar", 20, 0, 0).cast_target(), "nvarchar(max)");
        assert_eq!(system("decimal", 9, 10, 2).cast_target(), "decimal(10,2)");
        assert_eq!(system("hierarchyid", 892, 0, 0).cast_target(), "hierarchyid");
    }
}
