//! Catalog reads are written once for every release the driver supports.
//! A column or function a release added is written as a placeholder at
//! the spot it goes, and each read is rendered for the server it runs on.

use tablepro_core::ServerInfo;

/// The release a catalog read is rendered for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct CatalogRelease {
    major: u32,
}

/// One placeholder: the text from the release that added it on, and
/// what a server before that release has in its place.
struct Fragment {
    placeholder: &'static str,
    since: u32,
    current: &'static str,
    before: &'static str,
}

const FRAGMENTS: &[Fragment] = &[
    // 11 split procedures out of functions; before it an aggregate and a
    // window function are flags and every routine is a function.
    Fragment {
        placeholder: "{p.prokind}",
        since: 11,
        current: "p.prokind",
        before: "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END",
    },
    // INCLUDE columns came in 11, so before it every column is a key.
    Fragment {
        placeholder: "{i.indnkeyatts}",
        since: 11,
        current: "i.indnkeyatts",
        before: "i.indnatts",
    },
    // A partition's copy of a key came in 11; before it every key is its
    // table's own.
    Fragment {
        placeholder: "{c.conparentid}",
        since: 11,
        current: "c.conparentid",
        before: "0::pg_catalog.oid",
    },
    Fragment {
        placeholder: "{k.conparentid}",
        since: 11,
        current: "k.conparentid",
        before: "0::pg_catalog.oid",
    },
    Fragment {
        placeholder: "{a.attgenerated}",
        since: 12,
        current: "a.attgenerated",
        before: "''::pg_catalog.text",
    },
    // Before 13 a partition's copy of its parent's trigger is internal,
    // so `NOT tgisinternal` already leaves it out (measured on 11 and 12).
    Fragment {
        placeholder: "{t.tgparentid}",
        since: 13,
        current: "t.tgparentid",
        before: "0::pg_catalog.oid",
    },
    Fragment {
        placeholder: "{a.attcompression}",
        since: 14,
        current: "a.attcompression",
        before: "''",
    },
    // A table never vacuumed or analysed has reltuples -1 from 14 on.
    // Before 14 it has reltuples 0 and relpages 0, which an analysed empty
    // table also has.
    Fragment {
        placeholder: "{c.never_analysed}",
        since: 14,
        current: "c.reltuples < 0::pg_catalog.float4",
        before: "(c.reltuples = 0::pg_catalog.float4 AND c.relpages = 0)",
    },
    // A body in standard SQL came in 14 and names the tables it reads.
    Fragment {
        placeholder: "{p.sql_body_reads_a_table}",
        since: 14,
        current: "(p.prosqlbody IS NOT NULL AND EXISTS (SELECT 1 FROM pg_catalog.pg_depend dep
       WHERE dep.classid = 'pg_catalog.pg_proc'::pg_catalog.regclass AND dep.objid = p.oid
         AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass))",
        before: "false",
    },
];

impl CatalogRelease {
    pub(crate) const fn new(major: u32) -> Self {
        Self { major }
    }

    pub(crate) fn of(server: &ServerInfo) -> Self {
        Self::new(server.major)
    }

    pub(crate) fn render(self, sql: &str) -> String {
        FRAGMENTS.iter().fold(sql.to_owned(), |sql, fragment| {
            let text = match self.major >= fragment.since {
                true => fragment.current,
                false => fragment.before,
            };
            sql.replace(fragment.placeholder, text)
        })
    }
}

#[cfg(test)]
pub(crate) const SUPPORTED: [CatalogRelease; 9] = [
    CatalogRelease::new(10),
    CatalogRelease::new(11),
    CatalogRelease::new(12),
    CatalogRelease::new(13),
    CatalogRelease::new(14),
    CatalogRelease::new(15),
    CatalogRelease::new(16),
    CatalogRelease::new(17),
    CatalogRelease::new(18),
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_placeholder_takes_the_release_that_added_its_column() {
        let sql = "SELECT {p.prokind}, {i.indnkeyatts}, {t.tgparentid}";
        assert_eq!(
            CatalogRelease::new(10).render(sql),
            "SELECT CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END, i.indnatts, \
             0::pg_catalog.oid"
        );
        assert_eq!(
            CatalogRelease::new(12).render(sql),
            "SELECT p.prokind, i.indnkeyatts, 0::pg_catalog.oid"
        );
        assert_eq!(
            CatalogRelease::new(13).render(sql),
            "SELECT p.prokind, i.indnkeyatts, t.tgparentid"
        );
    }

    #[test]
    fn every_fragment_is_a_distinct_placeholder() {
        for (index, fragment) in FRAGMENTS.iter().enumerate() {
            assert!(fragment.placeholder.starts_with('{') && fragment.placeholder.ends_with('}'));
            assert!(
                FRAGMENTS[index + 1..]
                    .iter()
                    .all(|other| other.placeholder != fragment.placeholder),
                "{}",
                fragment.placeholder
            );
        }
    }
}
