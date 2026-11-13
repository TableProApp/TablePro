use std::sync::Arc;

use secrecy::{ExposeSecret as _, SecretString};
use tablepro_account::{ShareExpiry, ShareKind, ShareLimits, ShareRequest};
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{Snapshot, build_snapshot};
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
    // The result's own count, which the run's row limit may have cut; at least `rows.len()`.
    pub row_count: u64,
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
    // Cut to the plan's rows before upload, as the server would cut them.
    pub(crate) fn snapshot(&self, max_rows: u64) -> Snapshot {
        let max_rows = usize::try_from(max_rows).unwrap_or(usize::MAX);
        build_snapshot(
            &self.columns,
            self.rows.iter().take(max_rows).map(RowSnapshot::to_values),
            self.row_count.max(self.rows.len() as u64),
            max_rows,
        )
    }

    pub(crate) fn total(&self) -> u64 {
        self.row_count.max(self.rows.len() as u64)
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Value;
    use tablepro_core::column::{ColumnType, classify_type_name};

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

    fn rows(count: i64, row_count: u64) -> SharedRows {
        SharedRows {
            columns: vec![column("id"), column("api_token")].into(),
            rows: (0..count)
                .map(|id| RowSnapshot::new(vec![Value::Int(id), Value::Int(id * 10)].into(), Vec::new()))
                .collect(),
            row_count,
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
        }
    }

    fn query(sql: &str) -> ShareSubject {
        ShareSubject::query(String::new(), sql.to_owned(), Some("postgres".to_owned()))
    }

    #[test]
    fn a_free_plan_sends_none_of_the_pro_options() {
        let subject = ShareSubject {
            rows: Some(rows(2, 2)),
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
            rows: Some(rows(2, 2)),
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
            rows: Some(rows(1, 1)),
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
        let snapshot = rows(1, 1).snapshot(10);
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
        let shared = rows(12, 48_210);

        let snapshot = shared.snapshot(5);

        assert_eq!(snapshot.rows.len(), 5);
        assert_eq!(snapshot.row_count, 48_210);
        assert!(snapshot.truncated());
        assert_eq!(snapshot.rows[4][1].get(), "40");
        assert_eq!(shared.total(), 48_210);
        assert_eq!(rows(3, 0).total(), 3, "a count below the rows held is never sent");
    }

    #[test]
    fn secrets_are_found_in_the_sql_and_the_columns() {
        let subject = ShareSubject {
            rows: Some(rows(1, 1)),
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
