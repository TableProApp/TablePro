use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, PoisonError, RwLock, Weak};

use super::glob::glob_matches;
use super::{ColumnMasks, MaskingRule, MaskingStyle, MaskingTarget};
use crate::column::ResultColumn;
use crate::meta::TableRef;

// The rules one connection masks its values by, and the only place they are matched against columns.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MaskingPolicy {
    rules: Arc<[MaskingRule]>,
}

impl MaskingPolicy {
    // A rule with a blank pattern is left out.
    pub fn new(rules: impl IntoIterator<Item = MaskingRule>) -> Self {
        Self {
            rules: rules
                .into_iter()
                .filter(|rule| !rule.trimmed_pattern().is_empty())
                .collect(),
        }
    }

    pub fn none() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.rules.is_empty()
    }

    pub fn rules(&self) -> &[MaskingRule] {
        &self.rules
    }

    // The first rule that matches wins. Without a table, as for most query results, a `table.column` pattern
    // matches by its column part alone, so an unknown source masks more rather than less.
    pub fn style(&self, table: Option<&str>, column: &str, type_name: Option<&str>) -> Option<MaskingStyle> {
        if let Some(rule) = self.rules.iter().find(|rule| matches(rule, table, column, type_name)) {
            return Some(rule.style);
        }
        // Only after no rule matched as written, so a later column rule keeps beating a type rule that names no width.
        let base = base_type_name(type_name?);
        self.rules
            .iter()
            .find(|rule| rule.target == MaskingTarget::Type && glob_matches(rule.trimmed_pattern(), &base))
            .map(|rule| rule.style)
    }

    // By the names the result shows, for the grid. `table` is the table the rows come from when one is known.
    pub fn column_masks(&self, table: Option<&str>, columns: &[ResultColumn]) -> ColumnMasks {
        if self.is_empty() {
            return ColumnMasks::none();
        }
        ColumnMasks::new(
            columns
                .iter()
                .map(|column| self.style(table, &column.name, Some(&column.column_type.name)))
                .collect(),
        )
    }

    // For every path out of the app. A caller's statement can rename or compute a column, so an origin only adds
    // masking, and a column nobody traced is masked whole. `table` is set only for a statement the app wrote over that
    // one table's own columns; it matches by name when no column of the result carries an origin.
    pub fn external_column_masks(&self, table: Option<&str>, columns: &[ResultColumn]) -> ColumnMasks {
        if self.is_empty() {
            return ColumnMasks::none();
        }
        let by_name = proves_by_name(table, columns);
        ColumnMasks::new(
            columns
                .iter()
                .map(|column| {
                    let type_name = Some(column.column_type.name.as_str());
                    let Some(origin) = &column.origin else {
                        return match by_name {
                            true => self.style(table, &column.name, type_name),
                            false => Some(MaskingStyle::Full),
                        };
                    };
                    let relation = table_name(&origin.table);
                    // The relation can be a view, a partition or a child of the rule's table, so a `table.column`
                    // rule also matches by its column part; naming the relation only picks the style.
                    let read = self
                        .style(Some(&relation), &origin.column, type_name)
                        .or_else(|| self.style(None, &origin.column, type_name));
                    let named = match column.name.to_lowercase() == origin.column.to_lowercase() {
                        true => None,
                        false => self.style(None, &column.name, type_name),
                    };
                    MaskingStyle::strictest(read, named)
                })
                .collect(),
        )
    }

    // The columns `external_column_masks` masks only because nothing said what they read.
    pub fn untraced_columns(&self, table: Option<&str>, columns: &[ResultColumn]) -> Vec<usize> {
        if self.is_empty() || proves_by_name(table, columns) {
            return Vec::new();
        }
        columns
            .iter()
            .enumerate()
            .filter(|(_, column)| column.origin.is_none())
            .map(|(index, _)| index)
            .collect()
    }
}

// The macOS bridge reads "the driver reported no origins at all"; a result here carries one per column, so a result
// with none at all stands for that.
fn proves_by_name(table: Option<&str>, columns: &[ResultColumn]) -> bool {
    table.is_some() && columns.iter().all(|column| column.origin.is_none())
}

fn matches(rule: &MaskingRule, table: Option<&str>, column: &str, type_name: Option<&str>) -> bool {
    let pattern = rule.trimmed_pattern();
    match rule.target {
        MaskingTarget::Type => type_name.is_some_and(|type_name| glob_matches(pattern, type_name)),
        MaskingTarget::Column => {
            let Some((table_pattern, column_pattern)) = pattern.rsplit_once('.') else {
                return glob_matches(pattern, column);
            };
            if !glob_matches(column_pattern, column) {
                return false;
            }
            let Some(table) = table.filter(|table| !table.is_empty()) else {
                return true;
            };
            glob_matches(table_pattern, table)
                || table
                    .rsplit_once('.')
                    .is_some_and(|(_, bare)| glob_matches(table_pattern, bare))
        }
    }
}

// A table as a `table.column` rule names it: `schema.table`, or the table alone.
pub fn table_name(table: &TableRef) -> String {
    match &table.schema {
        Some(schema) => format!("{schema}.{}", table.name),
        None => table.name.clone(),
    }
}

// A result names `TINYINT(1)`, `BIT(8)` or `Nullable(String)` where a rule says `tinyint`, `bit` or `string`.
pub fn base_type_name(type_name: &str) -> String {
    let unwrapped = unwrapped_type_name(type_name);
    let head = unwrapped.split('(').next().unwrap_or_default();
    trim_blanks(head).to_owned()
}

// ClickHouse's `Nullable(String)` and `LowCardinality(Nullable(String))` are the type they wrap.
fn unwrapped_type_name(type_name: &str) -> &str {
    const WRAPPERS: [&str; 2] = ["NULLABLE(", "LOWCARDINALITY("];
    let mut name = trim_blanks(type_name);
    while name.ends_with(')') {
        let Some(wrapper) = WRAPPERS.iter().find(|wrapper| {
            name.get(..wrapper.len())
                .is_some_and(|head| head.eq_ignore_ascii_case(wrapper))
        }) else {
            break;
        };
        name = trim_blanks(&name[wrapper.len()..name.len() - 1]);
    }
    name
}

// Foundation's `.whitespaces`: tab and the space separators, never a line break.
fn trim_blanks(text: &str) -> &str {
    text.trim_matches(|character: char| {
        matches!(
            character,
            '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
        )
    })
}

// The policy a live session masks by now. A saved change replaces it, and every reader sees the new rules at once;
// the generation counts the changes, so a result set started earlier can tell it has to match again.
#[derive(Debug, Clone, Default)]
pub struct SharedMaskingPolicy {
    cell: Arc<PolicyCell>,
}

#[derive(Debug, Default)]
struct PolicyCell {
    policy: RwLock<MaskingPolicy>,
    generation: AtomicU64,
}

impl SharedMaskingPolicy {
    pub fn new(policy: MaskingPolicy) -> Self {
        Self {
            cell: Arc::new(PolicyCell {
                policy: RwLock::new(policy),
                generation: AtomicU64::new(0),
            }),
        }
    }

    pub fn get(&self) -> MaskingPolicy {
        self.cell.policy.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    // The same rules set again are no change.
    pub fn set(&self, policy: MaskingPolicy) {
        let mut held = self.cell.policy.write().unwrap_or_else(PoisonError::into_inner);
        if *held != policy {
            *held = policy;
            self.cell.generation.fetch_add(1, Ordering::AcqRel);
        }
    }

    // Moves on each change `set` makes.
    pub fn generation(&self) -> u64 {
        self.cell.generation.load(Ordering::Acquire)
    }

    // A handle that does not keep the session's rules alive, for the connection store to set on each save.
    pub fn downgrade(&self) -> WeakMaskingPolicy {
        WeakMaskingPolicy {
            cell: Arc::downgrade(&self.cell),
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct WeakMaskingPolicy {
    cell: Weak<PolicyCell>,
}

impl WeakMaskingPolicy {
    // None once every session holding the rules is gone.
    pub fn upgrade(&self) -> Option<SharedMaskingPolicy> {
        self.cell.upgrade().map(|cell| SharedMaskingPolicy { cell })
    }
}

#[cfg(test)]
mod tests {
    use super::MaskingStyle::{Email, Full, Hash, LastFour, Null};
    use super::*;
    use crate::column::{ColumnOrigin, ColumnType};

    fn column_rule(pattern: &str, style: MaskingStyle) -> MaskingRule {
        MaskingRule::new(pattern, MaskingTarget::Column, style)
    }

    fn type_rule(pattern: &str, style: MaskingStyle) -> MaskingRule {
        MaskingRule::new(pattern, MaskingTarget::Type, style)
    }

    fn policy(rules: Vec<MaskingRule>) -> MaskingPolicy {
        MaskingPolicy::new(rules)
    }

    fn column(name: &str, type_name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text(type_name))
    }

    fn traced(name: &str, schema: Option<&str>, table: &str, source: &str) -> ResultColumn {
        column(name, "text").with_origin(Some(ColumnOrigin::new(
            TableRef::new(schema.map(str::to_owned), table),
            source,
        )))
    }

    #[test]
    fn blank_patterns_are_left_out() {
        let policy = policy(vec![column_rule("  ", Full), type_rule("\n", Hash)]);

        assert!(policy.is_empty());
        assert_eq!(policy.style(None, "anything", Some("text")), None);
    }

    #[test]
    fn a_column_pattern_splits_at_its_last_dot_and_an_unknown_table_matches() {
        let policy = policy(vec![column_rule("users.email", Email)]);

        assert_eq!(policy.style(Some("users"), "email", None), Some(Email));
        assert_eq!(policy.style(Some("public.users"), "EMAIL", None), Some(Email));
        assert_eq!(policy.style(None, "email", None), Some(Email));
        assert_eq!(policy.style(Some(""), "email", None), Some(Email));
        assert_eq!(policy.style(Some("orders"), "email", None), None);
        assert_eq!(policy.style(Some("users"), "phone", None), None);

        let qualified = MaskingPolicy::new([column_rule("public.users.email", Email)]);
        assert_eq!(qualified.style(Some("public.users"), "email", None), Some(Email));
        assert_eq!(qualified.style(Some("users"), "email", None), None);
    }

    #[test]
    fn the_first_matching_rule_wins() {
        let policy = policy(vec![column_rule("*phone*", LastFour), column_rule("*", Full)]);

        assert_eq!(policy.style(None, "mobile_phone", None), Some(LastFour));
        assert_eq!(policy.style(None, "name", None), Some(Full));
    }

    #[test]
    fn a_type_rule_reads_the_full_type_then_the_unwrapped_base_type() {
        let policy = policy(vec![
            type_rule("tinyint", Null),
            type_rule("string", Hash),
            type_rule("varchar(255)", Full),
        ]);

        assert_eq!(policy.style(None, "flag", Some("TINYINT(1)")), Some(Null));
        assert_eq!(policy.style(None, "name", Some("Nullable(String)")), Some(Hash));
        assert_eq!(
            policy.style(None, "name", Some("LowCardinality(Nullable(String))")),
            Some(Hash)
        );
        assert_eq!(policy.style(None, "code", Some("varchar(255)")), Some(Full));
        assert_eq!(policy.style(None, "code", None), None);
        assert_eq!(policy.style(None, "n", Some("int")), None);
    }

    #[test]
    fn a_column_rule_after_a_type_rule_still_beats_its_base_type_match() {
        let policy = policy(vec![type_rule("varchar", Full), column_rule("email", Email)]);

        assert_eq!(policy.style(None, "email", Some("varchar(255)")), Some(Email));
        assert_eq!(policy.style(None, "name", Some("varchar(255)")), Some(Full));
    }

    #[test]
    fn base_type_names_unwrap_clickhouse_wrappers_and_drop_the_width() {
        assert_eq!(base_type_name("TINYINT(1)"), "TINYINT");
        assert_eq!(base_type_name("  Nullable( String ) "), "String");
        assert_eq!(base_type_name("lowcardinality(nullable(String))"), "String");
        assert_eq!(base_type_name("numeric (10, 2)"), "numeric");
        assert_eq!(base_type_name("Array(Nullable(String))"), "Array");
        assert_eq!(base_type_name(""), "");
    }

    #[test]
    fn grid_masks_go_by_the_names_the_result_shows() {
        let policy = policy(vec![column_rule("users.email", Email)]);
        let columns = [column("id", "int"), column("email", "text")];

        let masks = policy.column_masks(Some("users"), &columns);

        assert_eq!(masks.styles(), [None, Some(Email)]);
        assert!(MaskingPolicy::none().column_masks(None, &columns).is_empty());
    }

    #[test]
    fn an_external_caller_is_masked_by_what_each_column_reads() {
        let policy = policy(vec![column_rule("users.email", Email), column_rule("ssn", LastFour)]);
        let columns = [
            traced("email", Some("public"), "users", "email"),
            traced("contact", None, "users", "email"),
            traced("ssn", None, "orders", "email"),
            traced("name", None, "users", "name"),
            column("total", "numeric"),
        ];

        let masks = policy.external_column_masks(None, &columns);

        assert_eq!(masks.styles(), [Some(Email), Some(Email), Some(Full), None, Some(Full)]);
        assert_eq!(policy.untraced_columns(None, &columns), [4]);
    }

    #[test]
    fn a_traced_column_of_another_relation_still_matches_by_its_column_part() {
        let policy = policy(vec![column_rule("users.email", Email)]);

        let masks = policy.external_column_masks(None, &[traced("email", None, "users_view", "email")]);

        assert_eq!(masks.styles(), [Some(Email)]);
    }

    #[test]
    fn the_app_s_own_statement_over_one_table_matches_by_name() {
        let policy = policy(vec![column_rule("users.email", Email)]);
        let columns = [column("id", "int"), column("email", "text")];

        assert_eq!(
            policy.external_column_masks(Some("users"), &columns).styles(),
            [None, Some(Email)]
        );
        assert_eq!(
            policy.external_column_masks(Some("orders"), &columns).styles(),
            [None, None]
        );
        assert!(policy.untraced_columns(Some("users"), &columns).is_empty());
        assert_eq!(
            policy.external_column_masks(None, &columns).styles(),
            [Some(Full), Some(Full)]
        );
    }

    #[test]
    fn with_some_origins_a_known_table_no_longer_proves_by_name() {
        let policy = policy(vec![column_rule("email", Email)]);
        let columns = [traced("id", None, "users", "id"), column("email", "text")];

        assert_eq!(
            policy.external_column_masks(Some("users"), &columns).styles(),
            [None, Some(Full)]
        );
    }

    #[test]
    fn a_weak_handle_sets_the_rules_until_the_last_holder_goes() {
        let shared = SharedMaskingPolicy::default();
        let weak = shared.downgrade();

        weak.upgrade().expect("held").set(policy(vec![column_rule("*", Full)]));

        assert!(!shared.get().is_empty());
        drop(shared);
        assert!(weak.upgrade().is_none());
    }

    #[test]
    fn the_generation_moves_on_a_change_and_not_on_the_same_rules() {
        let shared = SharedMaskingPolicy::default();
        let rules = policy(vec![column_rule("*", Full)]);

        shared.set(rules.clone());
        shared.set(rules);
        let once = shared.generation();
        shared.set(MaskingPolicy::none());

        assert_eq!(once, 1);
        assert_eq!(shared.generation(), 2);
    }

    #[test]
    fn a_shared_policy_hands_every_reader_the_latest_rules() {
        let shared = SharedMaskingPolicy::default();
        let reader = shared.clone();

        shared.set(policy(vec![column_rule("*", Full)]));

        assert!(!reader.get().is_empty());
    }
}
