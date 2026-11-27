use std::sync::Arc;

use secrecy::{ExposeSecret as _, SecretString};
use tablepro_account::{ShareExpiry, ShareKind, ShareLimits, ShareRequest};
use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{ResultExtent, Snapshot, SnapshotRefusal, build_snapshot};
use tablepro_core::masking::detect::{MaskSuggestion, PersonalDataHit, scan_sql_personal_data};
use tablepro_core::masking::{ShareChoice, SharePlan, ShareSummary, share_suggestions};
use tablepro_core::secret_scan::{self, SecretHitKind};

use crate::services::grid::RowSnapshot;
use crate::services::share_table::TableShare;

#[derive(Debug, Clone)]
pub struct ShareSubject {
    pub title: String,
    pub sql: String,
    pub dialect: Option<String>,
    pub rows: Option<SharedRows>,
    pub table: Option<TableShare>,
    // Why a result goes without SQL, which the sheet says.
    pub no_sql: Option<String>,
}

#[derive(Debug, Clone)]
pub struct SharedRows {
    pub columns: Arc<[ResultColumn]>,
    pub rows: Vec<RowSnapshot>,
    // What the result knows of its rows, which the link names as the whole.
    pub extent: ResultExtent,
}

#[derive(Debug, Clone)]
pub struct ShareForm {
    pub title: String,
    pub note: String,
    pub expiry: ShareExpiry,
    pub hide_sql: bool,
    pub password: SecretString,
    pub allow_download: bool,
    // None shares a personal link.
    pub team: Option<String>,
    // The sheet's choice for each shared column, in order; Keep past its end.
    pub columns: Vec<ShareChoice>,
}

impl ShareSubject {
    pub(crate) fn query(title: String, sql: String, dialect: Option<String>) -> Self {
        Self {
            title,
            sql,
            dialect,
            rows: None,
            table: None,
            no_sql: None,
        }
    }

    pub(crate) fn kind(&self) -> ShareKind {
        match self.rows.is_some() || self.table.is_some() {
            true => ShareKind::Result,
            false => ShareKind::Query,
        }
    }

    pub(crate) fn has_sql(&self) -> bool {
        !self.sql.trim().is_empty()
    }

    // A plan's options it lacks are left out rather than refused by the server.
    pub(crate) fn request(&self, form: &ShareForm, limits: &ShareLimits, snapshot: Option<Snapshot>) -> ShareRequest {
        let result = self.kind() == ShareKind::Result;
        let password = form.password.expose_secret();
        ShareRequest {
            kind: self.kind(),
            sql: self.sql.clone(),
            title: Some(form.title.trim().to_owned()).filter(|title| !title.is_empty()),
            note: Some(form.note.trim().to_owned()).filter(|note| !note.is_empty()),
            dialect: self.dialect.clone().filter(|dialect| !dialect.is_empty()),
            expiry: Some(form.expiry).filter(|expiry| limits.expiries.contains(expiry)),
            hide_sql: result && self.has_sql() && form.hide_sql,
            allow_download: (limits.disable_download && !form.allow_download).then_some(false),
            password: (limits.password && !password.is_empty()).then(|| form.password.clone()),
            team_id: form
                .team
                .clone()
                .filter(|team| limits.team && limits.teams.iter().any(|known| known.id == *team)),
            snapshot: snapshot.filter(|_| result),
        }
    }

    pub(crate) fn secret_kinds(&self) -> Vec<SecretHitKind> {
        let mut kinds: Vec<SecretHitKind> = secret_scan::scan_sql(&self.sql)
            .into_iter()
            .map(|hit| hit.kind)
            .collect();
        kinds.sort_unstable();
        kinds.dedup();
        kinds
    }

    pub(crate) fn secret_columns(&self) -> Vec<String> {
        secret_scan::scan_columns(&self.column_names())
    }

    // Personal data in the SQL's literals, which Hide SQL keeps off the link; each kind once.
    pub(crate) fn personal_data(&self) -> Vec<PersonalDataHit> {
        let mut hits = scan_sql_personal_data(&self.sql);
        hits.sort_by_key(|hit| hit.kind);
        hits.dedup_by_key(|hit| hit.kind);
        hits
    }

    // The columns the link carries, in their order, before the server's column cap.
    pub(crate) fn column_names(&self) -> Vec<String> {
        match (&self.rows, &self.table) {
            (Some(rows), _) => rows.columns.iter().map(|column| column.name.clone()).collect(),
            (None, Some(table)) => table
                .shown
                .iter()
                .filter_map(|index| table.columns.get(*index))
                .map(|column| column.name.clone())
                .collect(),
            (None, None) => Vec::new(),
        }
    }
}

impl SharedRows {
    // The sheet's choices; at most the server's columns are kept.
    pub(crate) fn plan(&self, choices: &[ShareChoice], max_columns: u64) -> SharePlan {
        SharePlan::new(
            self.columns.len(),
            choices,
            usize::try_from(max_columns).unwrap_or(usize::MAX),
        )
    }

    // Cut to the plan's rows and the body's budget before upload, masked values weighed; removed columns are never read.
    pub(crate) fn snapshot(&self, max_rows: u64, plan: &SharePlan) -> Result<Snapshot, SnapshotRefusal> {
        let max_rows = usize::try_from(max_rows).unwrap_or(usize::MAX);
        let columns = plan.columns(&self.columns);
        let rows = self.rows.iter().map(|row| self.sent_row(plan, row));
        let mut snapshot = build_snapshot(&columns, rows, self.extent, max_rows)?;
        for (column, masked) in snapshot.columns.iter_mut().zip(plan.masked()) {
            column.masked = masked;
        }
        Ok(snapshot)
    }

    // What the snapshot of `plan` sends, so the preview, the notes and the detectors read the rows that go.
    pub(crate) fn summary(&self, plan: &SharePlan, max_rows: u64) -> ShareSummary {
        plan.summary(
            &self.columns,
            self.rows.len(),
            |row, column| self.rows[row].value(column).clone(),
            usize::try_from(max_rows).unwrap_or(usize::MAX),
        )
    }

    // The first `count` rows as the link carries them, for the sheet's preview.
    pub(crate) fn sent(&self, plan: &SharePlan, count: usize) -> (Vec<ResultColumn>, Vec<RowSnapshot>) {
        let rows = self
            .rows
            .iter()
            .take(count)
            .map(|row| RowSnapshot::new(self.sent_row(plan, row).into(), Vec::new()))
            .collect();
        (plan.columns(&self.columns), rows)
    }

    fn sent_row(&self, plan: &SharePlan, row: &RowSnapshot) -> Vec<Value> {
        plan.row(&self.columns, |index| row.value(index).clone())
    }

    // What the detectors suggest for the sheet as it starts, by the core's windows of the held rows.
    pub(crate) fn suggestions(&self, max_rows: u64, max_columns: u64) -> Vec<Option<MaskSuggestion>> {
        share_suggestions(
            &self.columns,
            self.rows.iter().map(RowSnapshot::to_values),
            usize::try_from(max_rows).unwrap_or(usize::MAX),
            usize::try_from(max_columns).unwrap_or(usize::MAX),
        )
    }

    pub(crate) fn total(&self) -> u64 {
        self.extent
            .total
            .unwrap_or(self.extent.held)
            .max(self.rows.len() as u64)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, classify_type_name};
    use tablepro_core::masking::MaskingStyle;

    use super::*;

    fn limits(plan: &str) -> ShareLimits {
        let pro = plan == "pro";
        ShareLimits {
            plan: plan.to_owned(),
            live: 1,
            live_limit: if pro { 1_000 } else { 5 },
            max_rows: if pro { 10_000 } else { 1_000 },
            expiries: match pro {
                true => ShareExpiry::ALL.to_vec(),
                false => vec![ShareExpiry::OneDay, ShareExpiry::SevenDays, ShareExpiry::ThirtyDays],
            },
            default_expiry: Some(if pro {
                ShareExpiry::Never
            } else {
                ShareExpiry::ThirtyDays
            }),
            password: pro,
            disable_download: pro,
            team: pro,
            email_verified: true,
            sharing_disabled: false,
            max_columns: 100,
            teams: vec![tablepro_account::ShareTeam {
                id: "team_01".to_owned(),
                name: "Data".to_owned(),
                live: 2,
                live_limit: 1_000,
                public_links: true,
            }],
        }
    }

    fn column(name: &str) -> ResultColumn {
        ResultColumn::new(
            name,
            ColumnType {
                kind: classify_type_name("bigint"),
                ..ColumnType::untyped_text("bigint")
            },
        )
    }

    fn rows(count: i64, total: Option<u64>) -> SharedRows {
        SharedRows {
            columns: vec![column("id"), column("api_token")].into(),
            rows: (0..count)
                .map(|id| RowSnapshot::new(vec![Value::Int(id), Value::Int(id * 10)].into(), Vec::new()))
                .collect(),
            extent: ResultExtent {
                held: count as u64,
                total,
                cut: total.is_some_and(|total| total > count as u64),
            },
        }
    }

    fn form() -> ShareForm {
        ShareForm {
            title: "  Orders  ".to_owned(),
            note: " ".to_owned(),
            expiry: ShareExpiry::Never,
            hide_sql: true,
            password: SecretString::from("hunter2"),
            allow_download: false,
            team: Some("team_01".to_owned()),
            columns: Vec::new(),
        }
    }

    fn query(sql: &str) -> ShareSubject {
        ShareSubject::query(String::new(), sql.to_owned(), Some("postgres".to_owned()))
    }

    #[test]
    fn a_free_plan_sends_none_of_the_pro_options() {
        let subject = ShareSubject {
            rows: Some(rows(2, None)),
            ..query("SELECT 1")
        };

        let request = subject.request(&form(), &limits("free"), None);

        assert_eq!(request.kind, ShareKind::Result);
        assert_eq!(request.title.as_deref(), Some("Orders"));
        assert_eq!(request.note, None);
        assert_eq!(request.expiry, None, "never is a Pro expiry");
        assert!(request.password.is_none());
        assert_eq!(request.allow_download, None);
        assert!(request.hide_sql);
        assert_eq!(request.team_id, None, "a team link needs Pro");
    }

    #[test]
    fn a_pro_plan_sends_its_password_downloads_and_expiry() {
        let subject = ShareSubject {
            rows: Some(rows(2, None)),
            ..query("SELECT 1")
        };

        let request = subject.request(&form(), &limits("pro"), None);

        assert_eq!(request.expiry, Some(ShareExpiry::Never));
        assert_eq!(
            request
                .password
                .as_ref()
                .map(|password| password.expose_secret().to_owned()),
            Some("hunter2".to_owned())
        );
        assert_eq!(request.allow_download, Some(false));
        assert_eq!(request.dialect.as_deref(), Some("postgres"));
        assert_eq!(request.team_id.as_deref(), Some("team_01"));
    }

    #[test]
    fn a_result_without_sql_sends_none_to_hide_and_no_team_the_plan_does_not_list() {
        let subject = ShareSubject {
            rows: Some(rows(1, None)),
            ..query("  ")
        };
        let stranger = ShareForm {
            team: Some("team_99".to_owned()),
            ..form()
        };

        let request = subject.request(&stranger, &limits("pro"), None);

        assert!(!subject.has_sql());
        assert!(!request.hide_sql);
        assert_eq!(request.team_id, None);
    }

    #[test]
    fn a_query_always_shows_its_sql_and_carries_no_rows() {
        let shared = rows(1, None);
        let snapshot = shared.snapshot(10, &shared.plan(&[], 100)).expect("a snapshot");
        let empty_password = ShareForm {
            password: SecretString::from(""),
            allow_download: true,
            ..form()
        };

        let request = query("SELECT 1").request(&empty_password, &limits("pro"), Some(snapshot));

        assert_eq!(request.kind, ShareKind::Query);
        assert!(!request.hide_sql);
        assert!(request.snapshot.is_none());
        assert!(request.password.is_none());
        assert_eq!(request.allow_download, None);
    }

    #[test]
    fn the_snapshot_is_cut_to_the_plan_and_keeps_the_true_count() {
        let shared = rows(12, Some(48_210));

        let snapshot = shared.snapshot(5, &shared.plan(&[], 100)).expect("a snapshot");

        assert_eq!(snapshot.rows.len(), 5);
        assert_eq!(snapshot.row_count, Some(48_210));
        assert!(snapshot.truncated());
        assert_eq!(snapshot.rows[4][1].get(), "40");
        assert_eq!(shared.total(), 48_210);
        assert_eq!(rows(3, Some(0)).total(), 3, "a count below the rows held is never sent");
    }

    #[test]
    fn a_result_cut_with_no_count_shares_that_more_rows_exist() {
        let shared = SharedRows {
            extent: ResultExtent {
                held: 2,
                total: None,
                cut: true,
            },
            ..rows(2, None)
        };

        let snapshot = shared.snapshot(10, &shared.plan(&[], 100)).expect("a snapshot");

        assert_eq!((snapshot.row_count, snapshot.more_rows), (None, true));
        assert!(snapshot.truncated());
    }

    fn text_column(name: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("text"))
    }

    fn people() -> SharedRows {
        let text = |value: &str| Value::Text(value.to_owned());
        SharedRows {
            columns: vec![text_column("id"), text_column("email"), text_column("note")].into(),
            rows: vec![RowSnapshot::new(
                vec![text("1"), text("ann@example.com"), text("+1 555 0100")].into(),
                Vec::new(),
            )],
            extent: ResultExtent::complete(1),
        }
    }

    #[test]
    fn kept_columns_go_as_held() {
        let shared = people();

        let snapshot = shared.snapshot(10, &shared.plan(&[], 100)).expect("a snapshot");

        let cells: Vec<&str> = snapshot.rows[0].iter().map(|cell| cell.get()).collect();
        assert_eq!(cells, [r#""1""#, r#""ann@example.com""#, r#""+1 555 0100""#]);
        assert!(snapshot.columns.iter().all(|column| column.masked.is_none()));
    }

    #[test]
    fn removed_columns_are_never_sent_and_masked_ones_say_how() {
        let shared = people();
        let choices = [
            ShareChoice::Remove,
            ShareChoice::Mask(MaskingStyle::Email),
            ShareChoice::Mask(MaskingStyle::LastFour),
        ];

        let plan = shared.plan(&choices, 100);
        let snapshot = shared.snapshot(10, &plan).expect("a snapshot");
        let (columns, preview) = shared.sent(&plan, 5);

        let names: Vec<&str> = snapshot.columns.iter().map(|column| column.name.as_str()).collect();
        assert_eq!(names, ["email", "note"]);
        let cells: Vec<&str> = snapshot.rows[0].iter().map(|cell| cell.get()).collect();
        assert_eq!(cells, [r#""a•••@example.com""#, r#""••••0100""#]);
        assert_eq!(snapshot.columns[1].masked, Some(MaskingStyle::LastFour));
        assert_eq!(columns.len(), 2);
        assert_eq!(preview[0].value(1), &Value::Text("••••0100".to_owned()));
    }

    #[test]
    fn detection_reads_the_names_and_the_values() {
        let shared = people();

        let styles: Vec<Option<MaskingStyle>> = shared
            .suggestions(1_000, 100)
            .iter()
            .map(|suggestion| suggestion.map(|suggestion| suggestion.style))
            .collect();

        assert_eq!(styles, [None, Some(MaskingStyle::Email), Some(MaskingStyle::LastFour)]);
    }

    #[test]
    fn a_first_row_too_large_to_send_still_has_its_values_read() {
        let text = |value: &str| Value::Text(value.to_owned());
        let shared = SharedRows {
            columns: vec![text_column("blob"), text_column("notes")].into(),
            rows: vec![
                RowSnapshot::new(
                    vec![text(&"x".repeat(300 * 1_024)), text("ann@example.com")].into(),
                    Vec::new(),
                ),
                RowSnapshot::new(vec![text("small"), text("bob@example.com")].into(), Vec::new()),
            ],
            extent: ResultExtent::complete(2),
        };

        let styles: Vec<Option<MaskingStyle>> = shared
            .suggestions(1_000, 100)
            .iter()
            .map(|suggestion| suggestion.map(|suggestion| suggestion.style))
            .collect();

        assert_eq!(styles, [None, Some(MaskingStyle::Email)]);
    }

    #[test]
    fn personal_data_in_the_sql_is_named_once_per_kind() {
        let subject = query("SELECT * FROM users WHERE email = 'ann@example.com' OR email = 'bo@example.com'");

        let kinds: Vec<_> = subject.personal_data().iter().map(|hit| hit.kind).collect();

        assert_eq!(kinds, [tablepro_core::masking::detect::SensitiveKind::Email]);
        assert!(query("SELECT 1 -- 'ann@example.com'").personal_data().is_empty());
    }

    #[test]
    fn secrets_are_found_in_the_sql_and_the_columns() {
        let subject = ShareSubject {
            rows: Some(rows(1, None)),
            ..query("SELECT 'AKIAABCDEFGHIJKLMNOP';\nSELECT 'AKIAABCDEFGHIJKLMNOQ', password = 'x'")
        };

        assert_eq!(
            subject.secret_kinds(),
            vec![SecretHitKind::AwsAccessKey, SecretHitKind::AssignedSecret]
        );
        assert_eq!(subject.secret_columns(), vec!["api_token".to_owned()]);
        assert!(query("SELECT 1").secret_kinds().is_empty());
        assert!(query("SELECT 1").secret_columns().is_empty());
    }
}
