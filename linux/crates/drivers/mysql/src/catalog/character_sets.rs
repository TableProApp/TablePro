use std::collections::BTreeMap;

use tablepro_core::DriverError;
use tablepro_core::ddl::CharacterSet;

use super::catalog_cells::CatalogCells;

/// Each character set with the collation it takes by default.
pub(crate) const CHARACTER_SETS_SQL: &str = "\
SELECT CHARACTER_SET_NAME, DEFAULT_COLLATE_NAME FROM information_schema.CHARACTER_SETS";

/// Whether the server lists full collation names apart, as MariaDB 10.10
/// and later do. Told by the column, not the version.
pub(crate) const FULL_COLLATION_NAMES_SQL: &str = "\
SELECT COUNT(*) FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'information_schema' AND TABLE_NAME = 'COLLATION_CHARACTER_SET_APPLICABILITY'
AND COLUMN_NAME = 'FULL_COLLATION_NAME'";

/// MySQL, and MariaDB before 10.10.
pub(crate) const COLLATIONS_SQL: &str = "\
SELECT COLLATION_NAME, CHARACTER_SET_NAME FROM information_schema.COLLATIONS";

/// MariaDB 10.10 and later list a UCA 14 collation in COLLATIONS once,
/// with no character set, while a table or column names it in full, as
/// `utf8mb4_uca1400_ai_ci`, which only this table spells.
pub(crate) const FULL_COLLATIONS_SQL: &str = "\
SELECT FULL_COLLATION_NAME, CHARACTER_SET_NAME FROM information_schema.COLLATION_CHARACTER_SET_APPLICABILITY";

/// Every character set in name order, each with its collations in name
/// order. A default collation the collation rows leave out is added, so
/// it is always one to pick.
pub(crate) fn character_sets(
    sets: &[CatalogCells],
    collations: &[CatalogCells],
) -> Result<Vec<CharacterSet>, DriverError> {
    let mut by_set: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for row in collations {
        let name = row.required_text(0)?;
        if let Some(set) = row.text(1)? {
            by_set.entry(set).or_default().push(name);
        }
    }
    let mut listed = Vec::new();
    for row in sets {
        let name = row.required_text(0)?;
        let default_collation = row.required_text(1)?;
        let mut collations = by_set.remove(&name).unwrap_or_default();
        collations.push(default_collation.clone());
        collations.sort();
        collations.dedup();
        listed.push(CharacterSet {
            name,
            default_collation,
            collations,
        });
    }
    listed.sort_by(|left, right| left.name.as_str().cmp(right.name.as_str()));
    Ok(listed)
}

#[cfg(test)]
mod tests {
    use tablepro_core::value::Value;

    use super::*;

    fn row(table: &'static str, values: [Option<&str>; 2]) -> CatalogCells {
        CatalogCells::new(
            table,
            values
                .iter()
                .map(|value| value.map_or(Value::Null, |text| Value::Text(text.to_owned())))
                .collect(),
        )
    }

    #[test]
    fn collations_group_under_their_character_set_with_the_default_kept() {
        let sets = [
            row("CHARACTER_SETS", [Some("utf8mb4"), Some("utf8mb4_uca1400_ai_ci")]),
            row("CHARACTER_SETS", [Some("latin1"), Some("latin1_swedish_ci")]),
        ];
        let collations = [
            row("COLLATIONS", [Some("utf8mb4_bin"), Some("utf8mb4")]),
            row("COLLATIONS", [Some("latin1_swedish_ci"), Some("latin1")]),
            row("COLLATIONS", [Some("latin1_bin"), Some("latin1")]),
            row("COLLATIONS", [Some("uca1400_ai_ci"), None]),
        ];

        let listed = character_sets(&sets, &collations).expect("the character sets");

        assert_eq!(
            listed,
            [
                CharacterSet {
                    name: "latin1".to_owned(),
                    default_collation: "latin1_swedish_ci".to_owned(),
                    collations: vec!["latin1_bin".to_owned(), "latin1_swedish_ci".to_owned()],
                },
                CharacterSet {
                    name: "utf8mb4".to_owned(),
                    default_collation: "utf8mb4_uca1400_ai_ci".to_owned(),
                    collations: vec!["utf8mb4_bin".to_owned(), "utf8mb4_uca1400_ai_ci".to_owned()],
                },
            ]
        );
    }
}
