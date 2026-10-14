//! A table the Add Foreign Key dialog offers to reference.

use std::cell::{Cell, OnceCell};
use std::collections::BTreeSet;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, TableRef};

mod imp {
    use std::marker::PhantomData;

    use gtk4::prelude::*;

    use super::*;

    #[derive(Default, glib::Properties)]
    #[properties(wrapper_type = super::TableChoiceObject)]
    pub struct TableChoiceObject {
        pub(super) table: OnceCell<TableRef>,
        pub(super) qualified: Cell<bool>,
        /// What the combo row shows and searches.
        #[property(get = Self::label)]
        label: PhantomData<String>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for TableChoiceObject {
        const NAME: &'static str = "TableProTableChoiceObject";
        type Type = super::TableChoiceObject;
    }

    #[glib::derived_properties]
    impl ObjectImpl for TableChoiceObject {}

    impl TableChoiceObject {
        fn label(&self) -> String {
            match (self.table.get(), self.qualified.get()) {
                (Some(table), true) => match &table.schema {
                    Some(schema) => format!("{schema}.{}", table.name),
                    None => table.name.clone(),
                },
                (Some(table), false) => table.name.clone(),
                (None, _) => crate::i18n::gettext("None"),
            }
        }
    }
}

glib::wrapper! {
    pub struct TableChoiceObject(ObjectSubclass<imp::TableChoiceObject>);
}

impl TableChoiceObject {
    /// The choice of no table, which a combo row needs: it always has an
    /// item selected once it has any.
    pub(super) fn none() -> Self {
        glib::Object::new()
    }

    fn new(table: TableRef, qualified: bool) -> Self {
        let object: Self = glib::Object::new();
        let _ = object.imp().table.set(table);
        object.imp().qualified.set(qualified);
        object
    }

    pub(crate) fn table(&self) -> Option<&TableRef> {
        self.imp().table.get()
    }
}

/// The tables a foreign key can reference, by label. A view cannot be
/// referenced. The schema is named only where tables come from more than
/// one.
pub(super) fn table_choices(objects: &[ObjectInfo]) -> Vec<TableChoiceObject> {
    let tables: Vec<&ObjectInfo> = objects
        .iter()
        .filter(|object| matches!(object.kind, ObjectKind::Table | ObjectKind::PartitionedTable))
        .collect();
    let schemas: BTreeSet<Option<&str>> = tables.iter().map(|table| table.schema.as_deref()).collect();
    let qualified = schemas.len() > 1;
    let mut choices: Vec<TableChoiceObject> = tables
        .into_iter()
        .map(|table| TableChoiceObject::new(TableRef::new(table.schema.clone(), table.name.clone()), qualified))
        .collect();
    choices.sort_by_cached_key(TableChoiceObject::label);
    choices
}

#[cfg(test)]
mod tests {
    use super::*;

    fn object(schema: Option<&str>, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
            kind,
        }
    }

    fn labels(choices: &[TableChoiceObject]) -> Vec<String> {
        choices.iter().map(TableChoiceObject::label).collect()
    }

    #[test]
    fn only_tables_are_offered_and_named_with_their_schema_where_it_tells_them_apart() {
        let one_schema = [
            object(Some("public"), "users", ObjectKind::Table),
            object(Some("public"), "active_users", ObjectKind::View),
            object(Some("public"), "events", ObjectKind::PartitionedTable),
        ];
        let two_schemas = [
            object(Some("public"), "users", ObjectKind::Table),
            object(Some("billing"), "users", ObjectKind::Table),
        ];

        assert_eq!(labels(&table_choices(&one_schema)), ["events", "users"]);
        assert_eq!(labels(&table_choices(&two_schemas)), ["billing.users", "public.users"]);
        assert_eq!(
            table_choices(&two_schemas)[0].table(),
            Some(&TableRef::new(Some("billing".to_owned()), "users"))
        );
        assert_eq!(TableChoiceObject::none().table(), None);
        assert_eq!(TableChoiceObject::none().label(), "None");
    }
}
