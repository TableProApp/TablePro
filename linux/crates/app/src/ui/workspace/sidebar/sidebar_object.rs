use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::meta::{ObjectInfo, ObjectKind, SchemaInfo, TableRef};

use super::sidebar_object_imp as imp;

glib::wrapper! {
    /// One table or view as the sidebar's list model holds it. It never
    /// changes: a new object list replaces every object.
    pub struct SidebarObject(ObjectSubclass<imp::SidebarObject>);
}

/// The section a schema's objects go in.
const DEFAULT_RANK: u32 = 0;
const OTHER_RANK: u32 = 1;
const SYSTEM_RANK: u32 = 2;

impl SidebarObject {
    /// `schemas` places the object's section: an object without a
    /// schema is in the connection's default one.
    pub(crate) fn new(object: &ObjectInfo, schemas: &[SchemaInfo]) -> Self {
        let this: Self = glib::Object::new();
        let imp = this.imp();
        let table = TableRef::new(object.schema.clone(), object.name.clone());
        let (title, rank) = section_of(object.schema.as_deref(), schemas);
        let search = match &table.schema {
            Some(schema) => format!("{schema}.{}", table.name),
            None => table.name.clone(),
        };
        let _ = imp.search.set(search.to_lowercase());
        let _ = imp.title.set(title);
        imp.rank.set(rank);
        let _ = imp.kind.set(object.kind);
        let _ = imp.table.set(table);
        this
    }

    /// Always set: `new` is the only way to build one.
    pub(crate) fn table_ref(&self) -> TableRef {
        self.imp()
            .table
            .get()
            .cloned()
            .unwrap_or_else(|| TableRef::unqualified(String::new()))
    }

    pub(crate) fn kind(&self) -> ObjectKind {
        self.imp().kind.get().copied().unwrap_or(ObjectKind::Table)
    }

    /// What the row's tooltip and the tab it opens call the table.
    pub(crate) fn qualified_name(&self) -> String {
        let table = self.table_ref();
        match table.schema {
            Some(schema) => format!("{schema}.{}", table.name),
            None => table.name,
        }
    }
}

fn section_of(schema: Option<&str>, schemas: &[SchemaInfo]) -> (String, u32) {
    let Some(schema) = schema else {
        let title = schemas
            .iter()
            .find(|known| known.is_default)
            .map_or_else(|| crate::i18n::gettext("Tables"), |known| known.name.clone());
        return (title, DEFAULT_RANK);
    };
    let rank = match schemas.iter().find(|known| known.name == schema) {
        Some(known) if known.is_default => DEFAULT_RANK,
        Some(known) if known.is_system => SYSTEM_RANK,
        _ => OTHER_RANK,
    };
    (schema.to_owned(), rank)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn schema(name: &str, is_default: bool, is_system: bool) -> SchemaInfo {
        SchemaInfo {
            name: name.to_owned(),
            is_default,
            is_system,
        }
    }

    fn object(schema: Option<&str>, name: &str, kind: ObjectKind) -> ObjectInfo {
        ObjectInfo {
            schema: schema.map(str::to_owned),
            name: name.to_owned(),
            kind,
        }
    }

    #[gtk4::test]
    fn an_object_carries_its_section_icon_and_search_text() {
        let schemas = [
            schema("public", true, false),
            schema("pg_catalog", false, true),
            schema("sales", false, false),
        ];

        let default = SidebarObject::new(&object(Some("public"), "Users", ObjectKind::Table), &schemas);
        let other = SidebarObject::new(&object(Some("sales"), "totals", ObjectKind::MaterializedView), &schemas);
        let system = SidebarObject::new(&object(Some("pg_catalog"), "pg_class", ObjectKind::View), &schemas);

        assert_eq!(
            (default.section_title(), default.section_rank()),
            ("public".to_owned(), 0)
        );
        assert_eq!((other.section_title(), other.section_rank()), ("sales".to_owned(), 1));
        assert_eq!(system.section_rank(), 2);
        assert_eq!(default.search_text(), "public.users");
        assert_eq!(default.icon_name(), "view-grid-symbolic");
        assert_eq!(other.icon_name(), "view-paged-symbolic");
        assert_eq!(system.icon_name(), "view-list-symbolic");
        assert_eq!(default.table_ref(), TableRef::new(Some("public".to_owned()), "Users"));
    }

    #[gtk4::test]
    fn an_object_without_a_schema_is_in_the_default_section() {
        let attached = [schema("main", true, false), schema("archive", false, false)];

        let main = SidebarObject::new(&object(None, "notes", ObjectKind::Table), &attached);
        let bare = SidebarObject::new(&object(None, "notes", ObjectKind::Table), &[]);

        assert_eq!((main.section_title(), main.section_rank()), ("main".to_owned(), 0));
        assert_eq!(main.schema(), None);
        assert_eq!(main.search_text(), "notes");
        assert_eq!(bare.section_title(), "Tables");
    }

    #[gtk4::test]
    fn a_schema_the_list_does_not_name_is_an_ordinary_section() {
        let listed = [schema("shop", true, false)];

        let other = SidebarObject::new(&object(Some("analytics"), "events", ObjectKind::Table), &listed);

        assert_eq!(
            (other.section_title(), other.section_rank()),
            ("analytics".to_owned(), 1)
        );
    }
}
