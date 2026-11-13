use chrono::{DateTime, Utc};
use secrecy::SecretString;
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use tablepro_core::export::Snapshot;

use crate::cloud_api::v2::types;

// The server's caps on a snapshot's columns: more columns or a longer name is refused, so the rest are left out.
pub const MAX_SHARE_COLUMNS: usize = 100;
const COLUMN_NAME_CHARACTERS: usize = 256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShareKind {
    Query,
    Result,
}

// The server computes the expiry from its own clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ShareExpiry {
    OneDay,
    SevenDays,
    ThirtyDays,
    Never,
}

impl ShareKind {
    pub fn code(self) -> &'static str {
        match self {
            Self::Query => "query",
            Self::Result => "result",
        }
    }
}

impl ShareExpiry {
    pub const ALL: [Self; 4] = [Self::OneDay, Self::SevenDays, Self::ThirtyDays, Self::Never];

    pub fn code(self) -> &'static str {
        match self {
            Self::OneDay => "1d",
            Self::SevenDays => "7d",
            Self::ThirtyDays => "30d",
            Self::Never => "never",
        }
    }

    pub fn from_code(code: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|expiry| expiry.code() == code)
    }
}

// What the account's plan allows, and where it stands. Plan and codes stay strings, as the profile's do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareLimits {
    pub plan: String,
    pub live: u64,
    pub live_limit: u64,
    pub max_rows: u64,
    // The same on every plan; a result with more shares the first ones.
    pub max_columns: u64,
    // An expiry this build does not know is left out.
    pub expiries: Vec<ShareExpiry>,
    pub default_expiry: Option<ShareExpiry>,
    pub password: bool,
    pub disable_download: bool,
    pub team: bool,
    pub email_verified: bool,
    pub sharing_disabled: bool,
    // The teams the account holds a seat in, for a team link; empty on Free.
    pub teams: Vec<ShareTeam>,
}

// A team link counts against the team's own limit, never the account's.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShareTeam {
    pub id: String,
    pub name: String,
    pub live: u64,
    pub live_limit: u64,
    // False: the team turned public links off, and a team link answers team_sharing_disabled.
    pub public_links: bool,
}

impl ShareLimits {
    pub fn at_limit(&self) -> bool {
        self.live >= self.live_limit
    }
}

impl ShareTeam {
    pub fn at_limit(&self) -> bool {
        self.live >= self.live_limit
    }
}

#[derive(Debug, Clone)]
pub struct ShareRequest {
    pub kind: ShareKind,
    pub sql: String,
    pub title: Option<String>,
    pub note: Option<String>,
    pub dialect: Option<String>,
    // None takes the plan's default.
    pub expiry: Option<ShareExpiry>,
    // Only for a result.
    pub hide_sql: bool,
    // None leaves downloads on.
    pub allow_download: Option<bool>,
    pub password: Option<SecretString>,
    pub team_id: Option<String>,
    // A result's rows, already cut to the plan's `max_rows`.
    pub snapshot: Option<Snapshot>,
}

// A link its owner manages. State, kind and scope stay strings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Share {
    pub id: String,
    pub kind: String,
    pub scope: String,
    pub team_id: Option<String>,
    pub title: String,
    pub note: String,
    pub dialect: String,
    // Only when one link is read on its own.
    pub sql: Option<String>,
    pub has_snapshot: bool,
    pub row_count: Option<u64>,
    pub truncated: Option<bool>,
    pub hide_sql: bool,
    pub allow_download: bool,
    pub has_password: bool,
    pub state: String,
    pub removed_reason: Option<String>,
    // A team turned public links off, staff turned the creator's sharing off, or the team was deleted: the link
    // does not resolve until the switch is on again. `suspended_by` is account, team or team_deleted.
    pub suspended: bool,
    pub suspended_by: Option<String>,
    pub view_count: u64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub revoked_at: Option<DateTime<Utc>>,
    pub removed_at: Option<DateTime<Utc>>,
    pub url: Option<String>,
}

impl Share {
    pub fn is_live(&self) -> bool {
        self.state == "live"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedShare {
    pub share: Share,
    pub url: String,
    // The result had more than `MAX_SHARE_COLUMNS` columns, and only the first ones were shared.
    pub columns_truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharePage {
    pub shares: Vec<Share>,
    pub next_cursor: Option<String>,
}

// A link as anyone with it reads it. The app opens its SQL and never its rows, so they are not kept.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharedLink {
    pub kind: String,
    pub title: String,
    pub note: String,
    pub dialect: String,
    // None when the owner hid it.
    pub sql: Option<String>,
    pub created_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    pub allow_download: bool,
    pub row_count: Option<u64>,
    pub truncated: Option<bool>,
}

// The document's SnapshotBody, which build.rs puts in place of the generated one: its rows go out as the raw JSON
// tokens the core wrote, where the generated `serde_json::Value` would round a big number.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SnapshotBody {
    pub columns: Vec<SnapshotColumnBody>,
    pub rows: Vec<Vec<Box<RawValue>>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub row_count: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotColumnBody {
    pub name: String,
    #[serde(rename = "type", default, skip_serializing_if = "Option::is_none")]
    pub type_name: Option<String>,
}

// The document's maxLength for a column's type.
const COLUMN_TYPE_CHARACTERS: usize = 256;

// Only the first `MAX_SHARE_COLUMNS` columns, and each row's cells for them.
impl From<Snapshot> for SnapshotBody {
    fn from(snapshot: Snapshot) -> Self {
        Self {
            columns: snapshot
                .columns
                .into_iter()
                .take(MAX_SHARE_COLUMNS)
                .map(|column| SnapshotColumnBody {
                    name: column.name.chars().take(COLUMN_NAME_CHARACTERS).collect(),
                    type_name: Some(column.type_name.chars().take(COLUMN_TYPE_CHARACTERS).collect())
                        .filter(|type_name: &String| !type_name.is_empty()),
                })
                .collect(),
            rows: snapshot
                .rows
                .into_iter()
                .map(|mut row| {
                    row.truncate(MAX_SHARE_COLUMNS);
                    row
                })
                .collect(),
            row_count: Some(i64::try_from(snapshot.row_count).unwrap_or(i64::MAX)),
        }
    }
}

// The document's PublicSnapshot, which build.rs puts in place of the generated one. Only the counts are read: the
// app opens a link's SQL, so its rows are skipped rather than parsed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct PublicSnapshot {
    pub row_count: i64,
    pub truncated: bool,
}

impl From<types::ShareLimits> for ShareLimits {
    fn from(limits: types::ShareLimits) -> Self {
        Self {
            plan: limits.plan.to_string(),
            live: count(limits.live),
            live_limit: count(limits.live_limit),
            max_rows: count(limits.max_rows),
            max_columns: MAX_SHARE_COLUMNS as u64,
            expiries: limits
                .expiries
                .iter()
                .filter_map(|expiry| ShareExpiry::from_code(&expiry.to_string()))
                .collect(),
            default_expiry: ShareExpiry::from_code(&limits.default_expiry.to_string()),
            password: limits.password,
            disable_download: limits.disable_download,
            team: limits.team,
            email_verified: limits.email_verified,
            sharing_disabled: limits.sharing_disabled,
            teams: limits
                .teams
                .into_iter()
                .map(|team| ShareTeam {
                    id: team.id,
                    name: team.name,
                    live: count(team.live),
                    live_limit: count(team.live_limit),
                    public_links: team.public_links,
                })
                .collect(),
        }
    }
}

impl From<types::ShareView> for Share {
    fn from(view: types::ShareView) -> Self {
        Self {
            id: view.id,
            kind: view.kind.to_string(),
            scope: view.scope.to_string(),
            team_id: view.team_id.filter(|team| !team.is_empty()),
            title: view.title,
            note: view.note,
            dialect: view.dialect,
            sql: view.sql,
            has_snapshot: view.has_snapshot,
            row_count: view.row_count.map(count),
            truncated: view.truncated,
            hide_sql: view.hide_sql,
            allow_download: view.allow_download,
            has_password: view.has_password,
            state: view.state.to_string(),
            removed_reason: view.removed_reason.filter(|reason| !reason.is_empty()),
            suspended: view.suspended,
            suspended_by: view.suspended_by.filter(|by| view.suspended && !by.is_empty()),
            view_count: count(view.view_count),
            created_at: view.created_at,
            updated_at: view.updated_at,
            expires_at: view.expires_at,
            revoked_at: view.revoked_at,
            removed_at: view.removed_at,
            url: view.url.filter(|url| !url.is_empty()),
        }
    }
}

impl From<types::CreatedShare> for CreatedShare {
    fn from(created: types::CreatedShare) -> Self {
        Self {
            share: created.share.into(),
            url: created.url,
            columns_truncated: false,
        }
    }
}

impl From<types::ShareList> for SharePage {
    fn from(list: types::ShareList) -> Self {
        Self {
            shares: list.data.into_iter().map(Share::from).collect(),
            next_cursor: list.next_cursor.filter(|cursor| !cursor.is_empty()),
        }
    }
}

impl From<types::PublicShare> for SharedLink {
    fn from(shared: types::PublicShare) -> Self {
        Self {
            kind: shared.kind.to_string(),
            title: shared.title,
            note: shared.note,
            dialect: shared.dialect,
            sql: shared.sql,
            created_at: shared.created_at,
            expires_at: shared.expires_at,
            allow_download: shared.allow_download,
            row_count: shared.snapshot.map(|snapshot| count(snapshot.row_count)),
            truncated: shared.snapshot.map(|snapshot| snapshot.truncated),
        }
    }
}

// A count the server sends as a signed integer, never below zero.
fn count(number: i64) -> u64 {
    u64::try_from(number).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use tablepro_core::column::{ColumnType, ResultColumn};
    use tablepro_core::export::build_snapshot;
    use tablepro_core::value::Value;

    use super::*;

    #[test]
    fn a_snapshot_shares_its_first_100_columns_with_names_cut_to_the_server_s_length() {
        let mut columns: Vec<ResultColumn> = (0..=MAX_SHARE_COLUMNS)
            .map(|index| ResultColumn::new(format!("c{index}"), ColumnType::untyped_text("text")))
            .collect();
        columns[0].name = "n".repeat(300);
        let row: Vec<Value> = (0..=MAX_SHARE_COLUMNS).map(|index| Value::Int(index as i64)).collect();

        let body = SnapshotBody::from(build_snapshot(&columns, [row], 1, 10));

        assert_eq!(body.columns.len(), MAX_SHARE_COLUMNS);
        assert_eq!(body.columns[0].name.chars().count(), 256);
        assert_eq!(body.columns[99].name, "c99");
        assert_eq!(body.rows[0].len(), MAX_SHARE_COLUMNS);
        assert_eq!(body.rows[0][99].get(), "99");
    }

    fn view(suspended: bool, by: &str) -> Share {
        let json = format!(
            r#"{{"id":"shr_01","kind":"query","scope":"team","team_id":"team_01","title":"","note":"","dialect":"",
            "has_snapshot":false,"hide_sql":false,"allow_download":true,"has_password":false,"state":"live",
            "suspended":{suspended},"suspended_by":"{by}","view_count":0,
            "created_at":"2026-11-13T00:00:00Z","updated_at":"2026-11-13T00:00:00Z"}}"#
        );
        serde_json::from_str::<types::ShareView>(&json).expect("a share").into()
    }

    #[test]
    fn a_suspended_link_says_who_suspended_it() {
        let deleted = view(true, "team_deleted");
        let live = view(false, "team");

        assert!(deleted.suspended);
        assert_eq!(deleted.suspended_by.as_deref(), Some("team_deleted"));
        assert!(!live.suspended);
        assert_eq!(live.suspended_by, None);
    }
}
