use std::collections::BTreeSet;

use bson::Bson;
use bson::spec::BinarySubtype;
use tablepro_core::ColumnInfo;
use tablepro_core::column::{
    BoolStorage, ColumnDefault, ColumnKind, ColumnType, FloatWidth, IntegerKind, IntegerWidth, ReadForm, SqlExpression,
    TemporalZone, TextLength,
};

/// The `$type` alias of a value, with a UUID told apart from other
/// binary data since the grid shows and edits it as a UUID.
pub(crate) fn type_alias(value: &Bson) -> &'static str {
    match value {
        Bson::Double(_) => "double",
        Bson::String(_) => "string",
        Bson::Document(_) => "object",
        Bson::Array(_) => "array",
        Bson::Binary(binary) if binary.subtype == BinarySubtype::Uuid && binary.bytes.len() == 16 => "uuid",
        Bson::Binary(_) => "binData",
        Bson::Undefined => "undefined",
        Bson::ObjectId(_) => "objectId",
        Bson::Boolean(_) => "bool",
        Bson::DateTime(_) => "date",
        Bson::Null => "null",
        Bson::RegularExpression(_) => "regex",
        Bson::DbPointer(_) => "dbPointer",
        Bson::JavaScriptCode(_) => "javascript",
        Bson::Symbol(_) => "symbol",
        Bson::JavaScriptCodeWithScope(_) => "javascriptWithScope",
        Bson::Int32(_) => "int",
        Bson::Timestamp(_) => "timestamp",
        Bson::Int64(_) => "long",
        Bson::Decimal128(_) => "decimal",
        Bson::MinKey => "minKey",
        Bson::MaxKey => "maxKey",
    }
}

/// The type a field's values share, as the grid treats it. Numbers that
/// differ in width share the widest; a field of several other types, or
/// of documents, arrays or binary data, is JSON, which writes each value
/// as the type it is, a UUID's subtype included. A null names no type:
/// it fits any.
pub(crate) fn shared_type(aliases: &BTreeSet<&str>) -> &'static str {
    let typed: BTreeSet<&str> = aliases.iter().copied().filter(|alias| *alias != "null").collect();
    let numbers = ["int", "long", "double", "decimal"];
    if !typed.is_empty() && typed.iter().all(|alias| numbers.contains(alias)) {
        return ["decimal", "double", "long", "int"]
            .into_iter()
            .find(|widest| typed.contains(widest))
            .unwrap_or("int");
    }
    match typed.iter().next() {
        Some(&alias) if typed.len() == 1 => match alias {
            "string" => "string",
            "bool" => "bool",
            "date" => "date",
            "objectId" => "objectId",
            "uuid" => "uuid",
            "binData" => "binData",
            "object" => "object",
            "array" => "array",
            _ => "mixed",
        },
        _ => "mixed",
    }
}

/// The column type for one of `shared_type`'s names.
pub(crate) fn column_type(name: &str) -> ColumnType {
    let kind = match name {
        "int" => ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W32,
            signed: true,
        }),
        "long" => ColumnKind::Integer(IntegerKind {
            width: IntegerWidth::W64,
            signed: true,
        }),
        "double" => ColumnKind::Float(FloatWidth::F64),
        "decimal" => ColumnKind::Decimal {
            precision: Some(34),
            scale: None,
        },
        "string" => ColumnKind::Text {
            length: TextLength::Unbounded,
        },
        "bool" => ColumnKind::Bool(BoolStorage::Native),
        "date" => ColumnKind::Timestamp {
            fractional_digits: Some(3),
            zone: TemporalZone::Offset,
        },
        "uuid" => ColumnKind::Uuid,
        // An ObjectId is its hex digits, which the driver reads back as one.
        "objectId" => ColumnKind::Other,
        _ => ColumnKind::Json { binary: false },
    };
    ColumnType {
        name: name.to_owned(),
        kind,
        catalog: None,
        dynamic_storage: false,
        read_form: ReadForm::Native,
    }
}

/// A field as a column of the collection's grid. `_id` names the
/// document: every document has one, and it is unique. A new document
/// left without one gets an ObjectId, so a new row leaves it out unless
/// the user types one.
pub(crate) fn field_column(name: &str, aliases: &BTreeSet<&str>) -> ColumnInfo {
    let id = name == "_id";
    ColumnInfo {
        name: name.to_owned(),
        column_type: column_type(shared_type(aliases)),
        nullable: !id,
        primary_key: id,
        is_auto_increment: false,
        is_generated: false,
        partition_scoped: false,
        default: match id {
            true => ColumnDefault::Expression(SqlExpression::from_catalog_text("ObjectId()")),
            false => ColumnDefault::None,
        },
        comment: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shared(aliases: &[&'static str]) -> &'static str {
        shared_type(&aliases.iter().copied().collect())
    }

    #[test]
    fn a_field_takes_the_type_its_values_share() {
        assert_eq!(shared(&["int"]), "int");
        assert_eq!(shared(&["int", "long"]), "long");
        assert_eq!(shared(&["int", "double", "null"]), "double");
        assert_eq!(shared(&["decimal", "int"]), "decimal");
        assert_eq!(shared(&["string", "null"]), "string");
        assert_eq!(shared(&["string", "int"]), "mixed");
        assert_eq!(shared(&["object"]), "object");
        assert_eq!(shared(&["null"]), "mixed");
        assert_eq!(shared(&["timestamp"]), "mixed");
    }

    #[test]
    fn the_id_names_the_document() {
        let id = field_column("_id", &["objectId"].into_iter().collect());
        assert!(id.primary_key && !id.nullable);
        assert!(id.default.needs_server_evaluation(), "a new row leaves _id out");
        assert_eq!(id.column_type.kind, ColumnKind::Other);
        assert!(matches!(
            field_column("tags", &["array"].into_iter().collect()).column_type.kind,
            ColumnKind::Json { .. }
        ));
    }
}
