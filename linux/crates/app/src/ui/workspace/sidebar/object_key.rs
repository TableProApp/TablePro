use std::borrow::Cow;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};

/// The table a sidebar menu item or action names, as its `(mss)` target:
/// the schema or nothing, then the name. The target travels through
/// GAction, so it is checked again where an action reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ObjectKey(pub TableRef);

impl ObjectKey {
    pub(crate) fn variant_type() -> Cow<'static, glib::VariantTy> {
        <(Option<String>, String)>::static_variant_type()
    }

    pub(crate) fn to_variant(&self) -> glib::Variant {
        (self.0.schema.clone(), self.0.name.clone()).to_variant()
    }

    /// `None` for a target of another shape, an empty name, or an empty
    /// schema, which no engine has.
    pub(crate) fn from_variant(variant: &glib::Variant) -> Option<Self> {
        let (schema, name) = variant.get::<(Option<String>, String)>()?;
        if name.is_empty() || schema.as_deref().is_some_and(str::is_empty) {
            return None;
        }
        Some(Self(TableRef::new(schema, name)))
    }
}

/// The routine, sequence or trigger a Show Definition item names, as its
/// `(msssms)` target: the schema or nothing, the name, the kind, then the
/// table a trigger fires on. Two triggers may share a name, so the table
/// is part of the key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DefinitionKey(pub ObjectInfo);

impl DefinitionKey {
    pub(crate) fn variant_type() -> Cow<'static, glib::VariantTy> {
        <(Option<String>, String, String, Option<String>)>::static_variant_type()
    }

    pub(crate) fn to_variant(&self) -> glib::Variant {
        let object = &self.0;
        (
            object.schema.clone(),
            object.name.clone(),
            kind_code(object.kind).to_owned(),
            object.table.clone(),
        )
            .to_variant()
    }

    /// `None` for a target of another shape, an empty name or schema, a
    /// kind with no definition, or a table given for anything but a
    /// trigger or missing from one.
    pub(crate) fn from_variant(variant: &glib::Variant) -> Option<Self> {
        let (schema, name, kind, table) = variant.get::<(Option<String>, String, String, Option<String>)>()?;
        let kind = kind_of_code(&kind)?;
        if name.is_empty() || schema.as_deref().is_some_and(str::is_empty) {
            return None;
        }
        if (kind == ObjectKind::Trigger) != table.as_deref().is_some_and(|table| !table.is_empty()) {
            return None;
        }
        Some(Self(ObjectInfo {
            schema,
            name,
            kind,
            table,
        }))
    }
}

fn kind_code(kind: ObjectKind) -> &'static str {
    match kind {
        ObjectKind::Function => "function",
        ObjectKind::Procedure => "procedure",
        ObjectKind::Sequence => "sequence",
        ObjectKind::Trigger => "trigger",
        _ => "",
    }
}

fn kind_of_code(code: &str) -> Option<ObjectKind> {
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

    #[test]
    fn definition_key_variant_round_trips() {
        let trigger = DefinitionKey(ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders"));
        let function = DefinitionKey(ObjectInfo::new(None, "total", ObjectKind::Function));

        assert_eq!(trigger.to_variant().type_().as_str(), "(msssms)");
        assert_eq!(DefinitionKey::variant_type().as_str(), "(msssms)");
        assert_eq!(DefinitionKey::from_variant(&trigger.to_variant()), Some(trigger));
        assert_eq!(DefinitionKey::from_variant(&function.to_variant()), Some(function));
    }

    #[test]
    fn a_definition_key_needs_a_definition_kind_and_a_trigger_its_table() {
        let target = |kind: &str, table: Option<&str>| {
            (
                None::<String>,
                "audit".to_owned(),
                kind.to_owned(),
                table.map(str::to_owned),
            )
                .to_variant()
        };

        assert_eq!(DefinitionKey::from_variant(&target("table", None)), None);
        assert_eq!(DefinitionKey::from_variant(&target("trigger", None)), None);
        assert_eq!(DefinitionKey::from_variant(&target("trigger", Some(""))), None);
        assert_eq!(DefinitionKey::from_variant(&target("function", Some("orders"))), None);
        assert!(DefinitionKey::from_variant(&target("sequence", None)).is_some());
    }

    #[test]
    fn object_key_variant_round_trips() {
        let qualified = ObjectKey(TableRef::new(Some("sales".to_owned()), "orders"));
        let bare = ObjectKey(TableRef::unqualified("notes"));

        assert_eq!(qualified.to_variant().type_().as_str(), "(mss)");
        assert_eq!(ObjectKey::variant_type().as_str(), "(mss)");
        assert_eq!(ObjectKey::from_variant(&qualified.to_variant()), Some(qualified));
        assert_eq!(ObjectKey::from_variant(&bare.to_variant()), Some(bare));
    }

    #[test]
    fn a_malformed_target_gives_no_key() {
        assert_eq!(ObjectKey::from_variant(&"orders".to_variant()), None);
        assert_eq!(ObjectKey::from_variant(&("sales", "orders").to_variant()), None);
        assert_eq!(
            ObjectKey::from_variant(&(None::<String>, String::new()).to_variant()),
            None
        );
        assert_eq!(
            ObjectKey::from_variant(&(Some(String::new()), "orders".to_owned()).to_variant()),
            None
        );
    }
}
