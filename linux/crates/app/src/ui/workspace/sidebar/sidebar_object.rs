use std::sync::Arc;

use gtk4::glib;
use gtk4::subclass::prelude::*;
use tablepro_core::meta::{KeyKind, ObjectInfo, ObjectKind, TableRef};

use super::sidebar_index::{IndexEntry, SidebarIndex};
use super::sidebar_object_imp as imp;

glib::wrapper! {
    /// One table, view or key as a sidebar list holds it. It reads its
    /// entry of the list's index rather than copying it: the tree makes
    /// one for every row of a schema it opens. It never changes: a new
    /// index replaces every object.
    pub struct SidebarObject(ObjectSubclass<imp::SidebarObject>);
}

impl SidebarObject {
    pub(crate) fn new(index: &Arc<SidebarIndex>, entry: u32) -> Self {
        let this: Self = glib::Object::new();
        let imp = this.imp();
        let _ = imp.index.set(index.clone());
        imp.entry.set(entry);
        this
    }

    fn row(&self) -> Option<&IndexEntry> {
        let imp = self.imp();
        imp.index.get()?.entry(imp.entry.get())
    }

    /// Always found: `new` is the only way to build one, from an entry
    /// its index holds.
    pub(crate) fn table_ref(&self) -> TableRef {
        self.row()
            .map_or_else(|| TableRef::unqualified(String::new()), |row| row.table.clone())
    }

    pub(crate) fn kind(&self) -> ObjectKind {
        self.row().map_or(ObjectKind::Table, |row| row.kind)
    }

    /// The table a trigger fires on.
    pub(crate) fn owner(&self) -> Option<String> {
        self.row().and_then(|row| row.owner.clone())
    }

    /// The object as its driver listed it, for a definition to be read.
    pub(crate) fn object_info(&self) -> ObjectInfo {
        let table = self.table_ref();
        ObjectInfo {
            schema: table.schema,
            name: table.name,
            kind: self.kind(),
            table: self.owner(),
        }
    }

    /// What the row's tooltip calls the object. A trigger is named
    /// after its table, whose name it shares a namespace with.
    pub(crate) fn qualified_name(&self) -> String {
        let table = self.table_ref();
        [table.schema, self.owner(), Some(table.name)]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(".")
    }

    /// The name says what the row is; the icon only tells a view from a
    /// table, or one kind of key from another, at a glance.
    pub(crate) fn icon_name(&self) -> &'static str {
        use crate::ui::icons;
        match self.kind() {
            ObjectKind::View => icons::VIEW_LIST,
            ObjectKind::MaterializedView => icons::VIEW_PAGED,
            ObjectKind::Function => icons::SYSTEM_RUN,
            ObjectKind::Procedure => icons::UTILITIES_TERMINAL,
            ObjectKind::Sequence => icons::VIEW_SORT_ASCENDING,
            ObjectKind::Trigger => icons::APPLICATIONS_ENGINEERING,
            ObjectKind::Key(kind) => match kind {
                KeyKind::String => icons::TEXT_X_GENERIC,
                KeyKind::Hash => icons::VIEW_GRID,
                KeyKind::List => icons::VIEW_LIST,
                KeyKind::Set => icons::VIEW_PAGED,
                KeyKind::SortedSet => icons::VIEW_SORT_ASCENDING,
                KeyKind::Stream => icons::DOCUMENT_OPEN_RECENT,
                KeyKind::Other => icons::VIEW_MORE,
            },
            _ => icons::VIEW_GRID,
        }
    }

    /// What a screen reader says the row is, which sighted users read
    /// from its icon.
    pub(crate) fn kind_name(&self) -> String {
        match self.kind() {
            ObjectKind::View => crate::i18n::pgettext("object kind", "View"),
            ObjectKind::MaterializedView => crate::i18n::pgettext("object kind", "Materialized View"),
            ObjectKind::Function => crate::i18n::pgettext("object kind", "Function"),
            ObjectKind::Procedure => crate::i18n::pgettext("object kind", "Procedure"),
            ObjectKind::Sequence => crate::i18n::pgettext("object kind", "Sequence"),
            ObjectKind::Trigger => crate::i18n::pgettext("object kind", "Trigger"),
            ObjectKind::Key(kind) => crate::ui::key_tab::key_kind_name(kind),
            _ => crate::i18n::pgettext("object kind", "Table"),
        }
    }

    /// What a key's row says it holds, or a trigger's the table it fires
    /// on, beside its name. A table's row says nothing: its icon tells a
    /// view from a table.
    pub(crate) fn type_label(&self) -> Option<String> {
        match self.kind() {
            ObjectKind::Key(kind) => Some(crate::ui::key_tab::key_kind_name(kind)),
            ObjectKind::Trigger => self.owner(),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::{ObjectInfo, SchemaInfo};

    use super::*;

    fn index(objects: &[(Option<&str>, &str, ObjectKind)]) -> Arc<SidebarIndex> {
        let objects: Vec<ObjectInfo> = objects
            .iter()
            .map(|(schema, name, kind)| ObjectInfo {
                schema: schema.map(str::to_owned),
                name: (*name).to_owned(),
                kind: *kind,
                table: None,
            })
            .collect();
        let main = SchemaInfo {
            name: "main".to_owned(),
            is_default: true,
            is_system: false,
        };
        Arc::new(SidebarIndex::build(&objects, &[main]))
    }

    /// The object of the entry named `name`.
    fn object(index: &Arc<SidebarIndex>, name: &str) -> SidebarObject {
        let entry = (0..)
            .map_while(|at| Some((at, index.entry(at)?)))
            .find(|(_, entry)| entry.table.name == name)
            .map(|(at, _)| at)
            .unwrap_or_else(|| panic!("no entry named {name}"));
        SidebarObject::new(index, entry)
    }

    #[gtk4::test]
    fn an_object_reads_its_table_icon_and_names_from_the_index() {
        let index = index(&[
            (Some("public"), "Users", ObjectKind::Table),
            (Some("public"), "Totals", ObjectKind::MaterializedView),
            (None, "notes", ObjectKind::View),
        ]);

        let (table, totals, view) = (
            object(&index, "Users"),
            object(&index, "Totals"),
            object(&index, "notes"),
        );

        assert_eq!(table.name(), "Users");
        assert_eq!(table.qualified_name(), "public.Users");
        assert_eq!(table.table_ref(), TableRef::new(Some("public".to_owned()), "Users"));
        assert_eq!(view.table_ref(), TableRef::unqualified("notes"));
        assert_eq!(view.qualified_name(), "notes");
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
        let key = |name: &str, kind| ObjectInfo {
            schema: None,
            name: name.to_owned(),
            kind: ObjectKind::Key(kind),
            table: None,
        };
        let index = Arc::new(SidebarIndex::keys(
            &[key("session:1", KeyKind::Hash), key("session:2", KeyKind::SortedSet)],
            "Database 0".to_owned(),
        ));

        let (hash, zset) = (object(&index, "session:1"), object(&index, "session:2"));

        assert_eq!(hash.kind_name(), "Hash");
        assert_eq!(hash.type_label().as_deref(), Some("Hash"));
        assert_eq!(zset.type_label().as_deref(), Some("Sorted Set"));
        assert_ne!(hash.icon_name(), zset.icon_name());
    }

    #[gtk4::test]
    fn a_routine_sequence_and_trigger_name_their_kind_and_a_trigger_its_table() {
        let objects = [
            ObjectInfo::new(Some("public".to_owned()), "total", ObjectKind::Function),
            ObjectInfo::new(Some("public".to_owned()), "archive", ObjectKind::Procedure),
            ObjectInfo::new(Some("public".to_owned()), "ids", ObjectKind::Sequence),
            ObjectInfo::trigger(Some("public".to_owned()), "audit", "orders"),
        ];
        let index = Arc::new(SidebarIndex::build(&objects, &[]));

        let rows: Vec<SidebarObject> = ["total", "archive", "ids", "audit"]
            .into_iter()
            .map(|name| object(&index, name))
            .collect();

        assert_eq!(
            rows.iter().map(SidebarObject::kind_name).collect::<Vec<_>>(),
            ["Function", "Procedure", "Sequence", "Trigger"]
        );
        let icons: std::collections::HashSet<&str> = rows.iter().map(SidebarObject::icon_name).collect();
        assert_eq!(icons.len(), 4, "each kind has an icon of its own");
        assert!(!icons.contains("view-grid-symbolic"), "none looks like a table");
        assert_eq!(rows[0].type_label(), None);
        assert_eq!(rows[3].type_label().as_deref(), Some("orders"));
        assert_eq!(rows[3].qualified_name(), "public.orders.audit");
        assert_eq!(rows[3].object_info(), objects[3]);
        assert_eq!(rows[0].object_info(), objects[0]);
    }
}
