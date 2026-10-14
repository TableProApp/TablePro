use std::borrow::Cow;

use gtk4::glib;
use gtk4::prelude::*;
use tablepro_core::meta::TableRef;

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

#[cfg(test)]
mod tests {
    use super::*;

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
