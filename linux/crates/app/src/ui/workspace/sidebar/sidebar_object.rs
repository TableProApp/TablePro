use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::meta::{ObjectKind, TableRef};

use super::sidebar_object_imp as imp;

glib::wrapper! {
    /// One table or view as the sidebar's list model holds it. It never
    /// changes: a new object list replaces every object.
    pub struct SidebarObject(ObjectSubclass<imp::SidebarObject>);
}

impl SidebarObject {
    /// `section_title` heads the section the object is in.
    pub(crate) fn new(table: &TableRef, kind: ObjectKind, section_title: &str) -> Self {
        let this: Self = glib::Object::new();
        let imp = this.imp();
        let _ = imp.title.set(section_title.to_owned());
        let _ = imp.kind.set(kind);
        let _ = imp.table.set(table.clone());
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

    /// What the row's tooltip calls the table.
    pub(crate) fn qualified_name(&self) -> String {
        let table = self.table_ref();
        match table.schema {
            Some(schema) => format!("{schema}.{}", table.name),
            None => table.name,
        }
    }

    /// What a screen reader says the row is, which sighted users read
    /// from its icon.
    pub(crate) fn kind_name(&self) -> String {
        match self.kind() {
            ObjectKind::View => crate::i18n::pgettext("object kind", "View"),
            ObjectKind::MaterializedView => crate::i18n::pgettext("object kind", "Materialized View"),
            ObjectKind::Key(kind) => crate::ui::key_tab::key_kind_name(kind),
            _ => crate::i18n::pgettext("object kind", "Table"),
        }
    }

    /// What a key's row says it holds, beside its name. A table's row
    /// says nothing: its icon tells a view from a table.
    pub(crate) fn type_label(&self) -> Option<String> {
        match self.kind() {
            ObjectKind::Key(kind) => Some(crate::ui::key_tab::key_kind_name(kind)),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::KeyKind;

    use super::*;

    #[gtk4::test]
    fn an_object_carries_its_section_icon_and_names() {
        let users = TableRef::new(Some("public".to_owned()), "Users");
        let notes = TableRef::unqualified("notes");

        let table = SidebarObject::new(&users, ObjectKind::Table, "public");
        let totals = SidebarObject::new(&users, ObjectKind::MaterializedView, "public");
        let view = SidebarObject::new(&notes, ObjectKind::View, "main");

        assert_eq!(table.section_title(), "public");
        assert_eq!(table.schema().as_deref(), Some("public"));
        assert_eq!(table.name(), "Users");
        assert_eq!(table.qualified_name(), "public.Users");
        assert_eq!(table.table_ref(), users);
        assert_eq!(view.schema(), None);
        assert_eq!(view.qualified_name(), "notes");
        assert_eq!(view.section_title(), "main");
        assert_eq!(table.icon_name(), "view-grid-symbolic");
        assert_eq!(totals.icon_name(), "view-paged-symbolic");
        assert_eq!(view.icon_name(), "view-list-symbolic");
        assert_eq!(
            [table.kind_name(), totals.kind_name(), view.kind_name()],
            ["Table", "Materialized View", "View"]
        );
        assert_eq!(table.type_label(), None);
    }

    #[gtk4::test]
    fn a_key_says_what_it_holds() {
        let session = TableRef::unqualified("session:1");

        let hash = SidebarObject::new(&session, ObjectKind::Key(KeyKind::Hash), "Database 0");
        let zset = SidebarObject::new(&session, ObjectKind::Key(KeyKind::SortedSet), "Database 0");

        assert_eq!(hash.kind_name(), "Hash");
        assert_eq!(hash.type_label().as_deref(), Some("Hash"));
        assert_eq!(zset.type_label().as_deref(), Some("Sorted Set"));
        assert_ne!(hash.icon_name(), zset.icon_name());
    }
}
