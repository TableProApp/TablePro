use std::borrow::Cow;
use std::collections::{BTreeSet, HashSet};

use tablepro_core::meta::{ObjectInfo, SchemaInfo};

// The schemas kept, as the macOS app keeps them: none kept lists every
// schema, and a schema made later stays out of a filter until it is added.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct SchemaFilter {
    kept: BTreeSet<String>,
}

impl SchemaFilter {
    pub(crate) fn new(kept: BTreeSet<String>) -> Self {
        Self { kept }
    }

    pub(crate) fn kept(&self) -> &BTreeSet<String> {
        &self.kept
    }

    // A kept name the list no longer holds counts for nothing, so a filter
    // of dropped schemas lists every schema rather than none.
    fn shown<'a>(&self, schemas: &'a [SchemaInfo]) -> Option<HashSet<&'a str>> {
        let shown: HashSet<&str> = schemas
            .iter()
            .map(|schema| schema.name.as_str())
            .filter(|name| self.kept.contains(*name))
            .collect();
        (!shown.is_empty() && shown.len() < schemas.len()).then_some(shown)
    }

    pub(crate) fn shows(&self, schemas: &[SchemaInfo], name: &str) -> bool {
        self.shown(schemas).is_none_or(|shown| shown.contains(name))
    }

    pub(crate) fn summary(&self, schemas: &[SchemaInfo]) -> Option<(usize, usize)> {
        self.shown(schemas).map(|shown| (shown.len(), schemas.len()))
    }

    // The last schema listed stays, and listing every schema clears the filter.
    pub(crate) fn set_shown(&mut self, schemas: &[SchemaInfo], name: &str, shown: bool) -> bool {
        if !schemas.iter().any(|schema| schema.name == name) || self.shows(schemas, name) == shown {
            return false;
        }
        let mut kept: BTreeSet<String> = schemas
            .iter()
            .filter(|schema| self.shows(schemas, &schema.name))
            .map(|schema| schema.name.clone())
            .collect();
        if shown {
            kept.insert(name.to_owned());
        } else {
            kept.remove(name);
        }
        if kept.is_empty() {
            return false;
        }
        if kept.len() == schemas.len() {
            kept.clear();
        }
        self.kept = kept;
        true
    }

    pub(crate) fn show_all(&mut self) -> bool {
        !std::mem::take(&mut self.kept).is_empty()
    }

    // An object with no schema is the default schema's.
    pub(crate) fn listed<'a>(
        &self,
        objects: &'a [ObjectInfo],
        schemas: &'a [SchemaInfo],
    ) -> (Cow<'a, [ObjectInfo]>, Cow<'a, [SchemaInfo]>) {
        let Some(shown) = self.shown(schemas) else {
            return (Cow::Borrowed(objects), Cow::Borrowed(schemas));
        };
        let default = schemas
            .iter()
            .find(|schema| schema.is_default)
            .map(|schema| schema.name.as_str());
        let objects = objects
            .iter()
            .filter(|object| {
                object
                    .schema
                    .as_deref()
                    .or(default)
                    .is_none_or(|schema| shown.contains(schema))
            })
            .cloned()
            .collect();
        let schemas = schemas
            .iter()
            .filter(|schema| shown.contains(schema.name.as_str()))
            .cloned()
            .collect();
        (Cow::Owned(objects), Cow::Owned(schemas))
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::meta::ObjectKind;

    use super::*;

    fn object(schema: Option<&str>, name: &str) -> ObjectInfo {
        ObjectInfo::new(schema.map(str::to_owned), name, ObjectKind::Table)
    }

    fn schemas(names: &[&str]) -> Vec<SchemaInfo> {
        names
            .iter()
            .enumerate()
            .map(|(at, name)| SchemaInfo {
                name: (*name).to_owned(),
                is_default: at == 0,
                is_system: false,
            })
            .collect()
    }

    fn names<T>(items: &[T], name: impl Fn(&T) -> &str) -> Vec<&str> {
        items.iter().map(name).collect()
    }

    fn kept(filter: &SchemaFilter) -> Vec<&str> {
        filter.kept().iter().map(String::as_str).collect()
    }

    #[test]
    fn nothing_kept_lists_everything_without_a_copy() {
        let (objects, schemas) = (vec![object(Some("public"), "users")], schemas(&["public", "sales"]));
        let filter = SchemaFilter::default();

        let (listed_objects, listed_schemas) = filter.listed(&objects, &schemas);

        assert!(matches!(listed_objects, Cow::Borrowed(_)));
        assert!(matches!(listed_schemas, Cow::Borrowed(_)));
        assert_eq!(filter.summary(&schemas), None);
    }

    #[test]
    fn a_schema_left_out_takes_its_objects_and_the_default_keeps_those_with_no_schema() {
        let objects = vec![
            object(Some("public"), "users"),
            object(Some("sales"), "leads"),
            object(None, "settings"),
        ];
        let schemas = schemas(&["public", "sales"]);
        let mut filter = SchemaFilter::default();

        assert!(filter.set_shown(&schemas, "sales", false));
        let (shown, listed) = filter.listed(&objects, &schemas);
        assert_eq!(names(&shown, |object| &object.name), ["users", "settings"]);
        assert_eq!(names(&listed, |schema| &schema.name), ["public"]);
        assert_eq!(filter.summary(&schemas), Some((1, 2)));

        let mut other = SchemaFilter::default();
        assert!(other.set_shown(&schemas, "public", false));
        assert_eq!(
            names(&other.listed(&objects, &schemas).0, |object| &object.name),
            ["leads"]
        );
    }

    #[test]
    fn a_schema_made_later_stays_out_until_it_is_listed() {
        let mut filter = SchemaFilter::default();
        assert!(filter.set_shown(&schemas(&["public", "sales", "audit"]), "audit", false));
        assert_eq!(kept(&filter), ["public", "sales"]);

        let grown = schemas(&["public", "sales", "audit", "billing"]);
        assert!(!filter.shows(&grown, "billing"));
        assert_eq!(filter.summary(&grown), Some((2, 4)));
    }

    #[test]
    fn the_last_schema_listed_stays_and_listing_every_one_clears_the_filter() {
        let schemas = schemas(&["public", "sales"]);
        let mut filter = SchemaFilter::default();
        assert!(filter.set_shown(&schemas, "sales", false));

        assert!(!filter.set_shown(&schemas, "public", false), "nothing would be listed");
        assert!(!filter.set_shown(&schemas, "nowhere", true));
        assert!(filter.set_shown(&schemas, "sales", true));
        assert!(filter.kept().is_empty());
        assert!(!filter.show_all(), "Show All with nothing left out");
    }

    #[test]
    fn a_kept_schema_that_was_dropped_counts_for_nothing() {
        let filter = SchemaFilter::new(BTreeSet::from(["gone".to_owned()]));
        let schemas = schemas(&["public", "sales"]);

        assert_eq!(filter.summary(&schemas), None);
        assert!(filter.shows(&schemas, "sales"));
    }
}
