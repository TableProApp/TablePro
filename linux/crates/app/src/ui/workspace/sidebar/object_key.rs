use std::borrow::Cow;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};

use super::object_target::ObjectTarget;

/// The object a sidebar menu item or action names, as its `(msssms)`
/// target: the schema or nothing, the name, what it opens as, then a
/// trigger's table. The target travels through GAction, so it is checked
/// again where an action reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ObjectKey(pub ObjectTarget);

const ROWS: &str = "rows";

impl ObjectKey {
    pub(crate) fn rows(table: TableRef) -> Self {
        Self(ObjectTarget::Rows(table))
    }

    pub(crate) fn variant_type() -> Cow<'static, glib::VariantTy> {
        <(Option<String>, String, String, Option<String>)>::static_variant_type()
    }

    pub(crate) fn to_variant(&self) -> glib::Variant {
        match &self.0 {
            ObjectTarget::Rows(table) => (table.schema.clone(), table.name.clone(), ROWS, None::<String>).to_variant(),
            ObjectTarget::Definition(object) => (
                object.schema.clone(),
                object.name.clone(),
                definition_code(object.kind).unwrap_or_default(),
                object.parent_table.clone(),
            )
                .to_variant(),
        }
    }

    /// `None` for a target of another shape, an empty name or schema,
    /// which no engine has, or a table given to anything but a trigger.
    pub(crate) fn from_variant(variant: &glib::Variant) -> Option<Self> {
        let (schema, name, code, parent) = variant.get::<(Option<String>, String, String, Option<String>)>()?;
        if name.is_empty() || schema.as_deref().is_some_and(str::is_empty) {
            return None;
        }
        if code == ROWS {
            return parent.is_none().then(|| Self::rows(TableRef::new(schema, name)));
        }
        let kind = definition_kind(&code)?;
        if (kind == ObjectKind::Trigger) != parent.as_deref().is_some_and(|parent| !parent.is_empty()) {
            return None;
        }
        Some(Self(ObjectTarget::Definition(ObjectInfo {
            schema,
            name,
            kind,
            parent_table: parent,
        })))
    }
}

fn definition_code(kind: ObjectKind) -> Option<&'static str> {
    Some(match kind {
        ObjectKind::Function => "function",
        ObjectKind::Procedure => "procedure",
        ObjectKind::Sequence => "sequence",
        ObjectKind::Trigger => "trigger",
        _ => return None,
    })
}

fn definition_kind(code: &str) -> Option<ObjectKind> {
    Some(match code {
        "function" => ObjectKind::Function,
        "procedure" => ObjectKind::Procedure,
        "sequence" => ObjectKind::Sequence,
        "trigger" => ObjectKind::Trigger,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn target(code: &str, parent: Option<&str>) -> glib::Variant {
        (None::<String>, "audit".to_owned(), code.to_owned(), parent.map(str::to_owned)).to_variant()
    }

    #[test]
    fn every_target_round_trips() {
        let keys = [
            ObjectKey::rows(TableRef::new(Some("sales".to_owned()), "orders")),
            ObjectKey::rows(TableRef::unqualified("notes")),
            ObjectKey(ObjectTarget::Definition(ObjectInfo::trigger(
                Some("public".to_owned()),
                "audit",
                "orders",
            ))),
            ObjectKey(ObjectTarget::Definition(ObjectInfo::new(None, "total", ObjectKind::Function))),
        ];

        assert_eq!(ObjectKey::variant_type().as_str(), "(msssms)");
        for key in keys {
            assert_eq!(key.to_variant().type_().as_str(), "(msssms)");
            assert_eq!(ObjectKey::from_variant(&key.to_variant()), Some(key));
        }
    }

    #[test]
    fn a_malformed_target_gives_no_key() {
        assert_eq!(ObjectKey::from_variant(&"orders".to_variant()), None);
        assert_eq!(ObjectKey::from_variant(&(None::<String>, "orders").to_variant()), None);
        assert_eq!(ObjectKey::from_variant(&target("rows", Some("orders"))), None);
        assert_eq!(ObjectKey::from_variant(&target("table", None)), None);
        assert_eq!(ObjectKey::from_variant(&target("trigger", None)), None);
        assert_eq!(ObjectKey::from_variant(&target("trigger", Some(""))), None);
        assert_eq!(ObjectKey::from_variant(&target("function", Some("orders"))), None);
        assert!(ObjectKey::from_variant(&target("sequence", None)).is_some());
        let empty_name = (None::<String>, String::new(), ROWS.to_owned(), None::<String>).to_variant();
        assert_eq!(ObjectKey::from_variant(&empty_name), None);
        let empty_schema = (Some(String::new()), "orders".to_owned(), ROWS.to_owned(), None::<String>).to_variant();
        assert_eq!(ObjectKey::from_variant(&empty_schema), None);
    }
}
