use std::sync::Arc;

use chrono::{DateTime, Utc};
use secrecy::SecretString;
use tablepro_account::{
    CreatedShare, MAX_SHARE_COLUMNS, Share, ShareExpiry, ShareKind, ShareLimits, SharePage, ShareRequest, ShareTeam,
    SharedLink,
};
use tablepro_core::Value;
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{ResultExtent, Snapshot, build_snapshot};
use tablepro_core::masking::ColumnMasks;

use super::account_service::AccountService;
use crate::error::CoreError;
use crate::export::held_row;
use crate::masking::{ShareColumnChoice, chosen_style};
use crate::results::ResultSet;
use crate::runtime::on_runtime;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShareKindTag {
    Query,
    Result,
}

// The server counts the expiry from its own clock.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ShareExpiryTag {
    OneDay,
    SevenDays,
    ThirtyDays,
    Never,
}

// Plan, kind, scope and state stay strings, as the account crate keeps them. Times are seconds from the Unix epoch.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareLimitsInfo {
    pub plan: String,
    pub live: u64,
    pub live_limit: u64,
    pub max_rows: u64,
    // A result with more visible columns shares the first ones, on every plan.
    pub max_columns: u64,
    pub expiries: Vec<ShareExpiryTag>,
    pub default_expiry: Option<ShareExpiryTag>,
    pub password: bool,
    pub disable_download: bool,
    pub team: bool,
    pub email_verified: bool,
    pub sharing_disabled: bool,
    // The teams the account holds a seat in, for a team link; empty on Free.
    pub teams: Vec<ShareTeamInfo>,
}

// A team link counts against the team's own `live_limit`. `public_links` false: the team turned them off.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareTeamInfo {
    pub id: String,
    pub name: String,
    pub live: u64,
    pub live_limit: u64,
    pub public_links: bool,
}

#[derive(Clone, uniffi::Record)]
pub struct ShareRequestArg {
    pub kind: ShareKindTag,
    pub sql: String,
    pub title: Option<String>,
    pub note: Option<String>,
    pub dialect: Option<String>,
    // None takes the plan's default.
    pub expiry: Option<ShareExpiryTag>,
    // Only for a result.
    pub hide_sql: bool,
    // None leaves downloads on.
    pub allow_download: Option<bool>,
    pub password: Option<SecretString>,
    pub team_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ShareInfo {
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
    // The link does not resolve until its switch is on again; `suspended_by` is account, team or team_deleted.
    pub suspended: bool,
    pub suspended_by: Option<String>,
    pub view_count: u64,
    pub created_at_secs: i64,
    pub updated_at_secs: i64,
    pub expires_at_secs: Option<i64>,
    pub revoked_at_secs: Option<i64>,
    pub removed_at_secs: Option<i64>,
    pub url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedShareInfo {
    pub share: ShareInfo,
    pub url: String,
    // Only the first `max_columns` of the visible columns were shared.
    pub columns_truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SharePageInfo {
    pub shares: Vec<ShareInfo>,
    pub next_cursor: Option<String>,
}

// A link as anyone with it reads it. The app opens its SQL in a new tab and never runs it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SharedLinkInfo {
    pub kind: String,
    pub title: String,
    pub note: String,
    pub dialect: String,
    // None when the owner hid it, so there is nothing to open.
    pub sql: Option<String>,
    pub created_at_secs: i64,
    pub expires_at_secs: Option<i64>,
    pub allow_download: bool,
    pub row_count: Option<u64>,
    pub truncated: Option<bool>,
}

#[uniffi::export]
impl AccountService {
    pub async fn share_limits(&self) -> Result<ShareLimitsInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move { Ok(account.share_limits().await?.into()) }).await
    }

    // A result share takes the set's first `visible_columns` columns and its first `max_rows` rows, the plan's
    // limit from `share_limits`; the set must have all its rows. A query share takes no set. For a table page, the
    // SQL is the page's `view_sql` and `total_rows` what `table_row_count` counts, since the set holds one page.
    // `columns` is the sheet's choice for each visible column, in order, Keep for any it leaves out; the connection's
    // rules mask on top of them, also for a tab the user revealed.
    pub async fn create_share(
        &self,
        request: ShareRequestArg,
        result: Option<Arc<ResultSet>>,
        visible_columns: u32,
        max_rows: u32,
        total_rows: Option<u64>,
        columns: Vec<ShareColumnChoice>,
    ) -> Result<CreatedShareInfo, CoreError> {
        let account = self.account.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let (snapshot, cut) = match (request.kind, result) {
                (ShareKindTag::Query, _) => (None, false),
                (ShareKindTag::Result, None) => {
                    return Err(CoreError::failed(
                        "ffi.share_needs_result",
                        "a result share needs its result set",
                    ));
                }
                (ShareKindTag::Result, Some(set)) => {
                    let (built, cut) = tasks
                        .spawn_blocking_task(move || snapshot_of(&set, visible_columns, max_rows, total_rows, &columns))
                        .await
                        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
                    (Some(built), cut)
                }
            };
            let created = account.create_share(share_request(request, snapshot)).await?;
            let mut info = CreatedShareInfo::from(created);
            info.columns_truncated |= cut;
            Ok(info)
        })
        .await
    }

    // The account's own links, or with `team_id` a team's, newest first, without their SQL.
    pub async fn list_shares(
        &self,
        live_only: bool,
        team_id: Option<String>,
        cursor: Option<String>,
    ) -> Result<SharePageInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            let page = account
                .list_shares(live_only, team_id.as_deref(), cursor.as_deref())
                .await?;
            Ok(page.into())
        })
        .await
    }

    pub async fn revoke_share(&self, share_id: String) -> Result<(), CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            account.revoke_share(&share_id).await.map_err(CoreError::from)
        })
        .await
    }

    // A new expiry from now; Free extends a link this way.
    pub async fn extend_share(&self, share_id: String, expiry: ShareExpiryTag) -> Result<ShareInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            Ok(account.extend_share(&share_id, expiry.into()).await?.into())
        })
        .await
    }

    // Public: it works signed out. `account.share_password_required` asks for the password,
    // `account.share_password_wrong` for it again.
    pub async fn fetch_shared(
        &self,
        token: String,
        password: Option<SecretString>,
    ) -> Result<SharedLinkInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            Ok(account.fetch_shared(&token, password.as_ref()).await?.into())
        })
        .await
    }
}

// Also whether columns past the server's cap were left out, before any of their cells is built. A removed column is
// never read; a masked one leaves masked, and the snapshot says how.
fn snapshot_of(
    set: &ResultSet,
    visible_columns: u32,
    max_rows: u32,
    total_rows: Option<u64>,
    choices: &[ShareColumnChoice],
) -> Result<(Snapshot, bool), CoreError> {
    // A set still reading would share the rows held so far as if they were all of them.
    if !set.is_finished() {
        return Err(CoreError::failed("ffi.share_unfinished", "the rows are still arriving"));
    }
    let held = set.result_columns();
    let visible = usize::try_from(visible_columns).unwrap_or(usize::MAX).min(held.len());
    let choice = |index: usize| choices.get(index).copied().unwrap_or(ShareColumnChoice::Keep);
    let kept: Vec<usize> = (0..visible)
        .filter(|index| choice(*index) != ShareColumnChoice::Remove)
        .collect();
    let cut = kept.len() > MAX_SHARE_COLUMNS;
    let kept = &kept[..kept.len().min(MAX_SHARE_COLUMNS)];
    let visible_set: Vec<ResultColumn> = held[..visible].to_vec();
    let rules = set.external_masks(&visible_set);
    let wanted = ColumnMasks::new(
        (0..visible)
            .map(|index| chosen_style(choice(index), rules.style(index)))
            .collect(),
    );
    let shown = set.shown_masks();
    let overlay = shown.overlay(&wanted);
    let left = shown.merged(&overlay);
    let ended = set.extent();
    let taken = ended.held.min(u64::from(max_rows));
    let columns: Vec<ResultColumn> = kept.iter().map(|index| held[*index].clone()).collect();
    let rows = (0..taken).map(|row| {
        let mut cells = held_row(set, row, &visible_set);
        overlay.apply(&visible_set, &mut cells);
        kept.iter()
            .map(|index| std::mem::replace(&mut cells[*index], Value::Null))
            .collect::<Vec<Value>>()
    });
    // A count the app made of a table view outranks what the page's own read knew.
    let extent = ResultExtent {
        total: total_rows.or(ended.total),
        ..ended
    };
    let mut snapshot = build_snapshot(&columns, rows, extent, usize::try_from(max_rows).unwrap_or(usize::MAX));
    for (column, index) in snapshot.columns.iter_mut().zip(kept) {
        column.masked = left.style(*index);
    }
    Ok((snapshot, cut))
}

fn share_request(request: ShareRequestArg, snapshot: Option<Snapshot>) -> ShareRequest {
    ShareRequest {
        kind: match request.kind {
            ShareKindTag::Query => ShareKind::Query,
            ShareKindTag::Result => ShareKind::Result,
        },
        sql: request.sql,
        title: request.title,
        note: request.note,
        dialect: request.dialect,
        expiry: request.expiry.map(ShareExpiry::from),
        hide_sql: request.hide_sql,
        allow_download: request.allow_download,
        password: request.password,
        team_id: request.team_id,
        snapshot,
    }
}

impl From<ShareExpiryTag> for ShareExpiry {
    fn from(expiry: ShareExpiryTag) -> Self {
        match expiry {
            ShareExpiryTag::OneDay => Self::OneDay,
            ShareExpiryTag::SevenDays => Self::SevenDays,
            ShareExpiryTag::ThirtyDays => Self::ThirtyDays,
            ShareExpiryTag::Never => Self::Never,
        }
    }
}

impl From<ShareExpiry> for ShareExpiryTag {
    fn from(expiry: ShareExpiry) -> Self {
        match expiry {
            ShareExpiry::OneDay => Self::OneDay,
            ShareExpiry::SevenDays => Self::SevenDays,
            ShareExpiry::ThirtyDays => Self::ThirtyDays,
            ShareExpiry::Never => Self::Never,
        }
    }
}

impl From<ShareLimits> for ShareLimitsInfo {
    fn from(limits: ShareLimits) -> Self {
        Self {
            plan: limits.plan,
            live: limits.live,
            live_limit: limits.live_limit,
            max_rows: limits.max_rows,
            max_columns: limits.max_columns,
            expiries: limits.expiries.into_iter().map(ShareExpiryTag::from).collect(),
            default_expiry: limits.default_expiry.map(ShareExpiryTag::from),
            password: limits.password,
            disable_download: limits.disable_download,
            team: limits.team,
            email_verified: limits.email_verified,
            sharing_disabled: limits.sharing_disabled,
            teams: limits.teams.into_iter().map(ShareTeamInfo::from).collect(),
        }
    }
}

impl From<ShareTeam> for ShareTeamInfo {
    fn from(team: ShareTeam) -> Self {
        Self {
            id: team.id,
            name: team.name,
            live: team.live,
            live_limit: team.live_limit,
            public_links: team.public_links,
        }
    }
}

impl From<Share> for ShareInfo {
    fn from(share: Share) -> Self {
        Self {
            id: share.id,
            kind: share.kind,
            scope: share.scope,
            team_id: share.team_id,
            title: share.title,
            note: share.note,
            dialect: share.dialect,
            sql: share.sql,
            has_snapshot: share.has_snapshot,
            row_count: share.row_count,
            truncated: share.truncated,
            hide_sql: share.hide_sql,
            allow_download: share.allow_download,
            has_password: share.has_password,
            state: share.state,
            removed_reason: share.removed_reason,
            suspended: share.suspended,
            suspended_by: share.suspended_by,
            view_count: share.view_count,
            created_at_secs: seconds(share.created_at),
            updated_at_secs: seconds(share.updated_at),
            expires_at_secs: share.expires_at.map(seconds),
            revoked_at_secs: share.revoked_at.map(seconds),
            removed_at_secs: share.removed_at.map(seconds),
            url: share.url,
        }
    }
}

impl From<CreatedShare> for CreatedShareInfo {
    fn from(created: CreatedShare) -> Self {
        Self {
            share: created.share.into(),
            url: created.url,
            columns_truncated: created.columns_truncated,
        }
    }
}

impl From<SharePage> for SharePageInfo {
    fn from(page: SharePage) -> Self {
        Self {
            shares: page.shares.into_iter().map(ShareInfo::from).collect(),
            next_cursor: page.next_cursor,
        }
    }
}

impl From<SharedLink> for SharedLinkInfo {
    fn from(shared: SharedLink) -> Self {
        Self {
            kind: shared.kind,
            title: shared.title,
            note: shared.note,
            dialect: shared.dialect,
            sql: shared.sql,
            created_at_secs: seconds(shared.created_at),
            expires_at_secs: shared.expires_at.map(seconds),
            allow_download: shared.allow_download,
            row_count: shared.row_count,
            truncated: shared.truncated,
        }
    }
}

fn seconds(at: DateTime<Utc>) -> i64 {
    at.timestamp()
}

impl std::fmt::Debug for ShareRequestArg {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ShareRequestArg")
            .field("kind", &self.kind)
            .field("expiry", &self.expiry)
            .field("hide_sql", &self.hide_sql)
            .field("allow_download", &self.allow_download)
            .field("has_password", &self.password.is_some())
            .finish_non_exhaustive()
    }
}

#[cfg(test)]
mod tests {
    use tablepro_core::Truncation;
    use tablepro_core::column::{ColumnOrigin, ColumnType};
    use tablepro_core::masking::{MaskingPolicy, MaskingRule, MaskingStyle, MaskingTarget, SharedMaskingPolicy};
    use tablepro_core::meta::TableRef;

    use super::*;
    use crate::masking::MaskStyleTag;
    use crate::results::{GridMasking, ResultStore};

    fn cut_set() -> ResultSet {
        let columns: Arc<[ResultColumn]> = vec![ResultColumn::new("n", ColumnType::untyped_text("int"))].into();
        let store = Arc::new(ResultStore::new(columns));
        store.append(&[vec![Value::Int(1)], vec![Value::Int(2)]]);
        store.finish_as(None, Truncation::ReadPastLimit);
        ResultSet::new(0, store)
    }

    #[test]
    fn a_set_cut_with_no_count_shares_that_more_rows_exist() {
        let (uncounted, _) = snapshot_of(&cut_set(), 1, 1_000, None, &[]).unwrap();
        let (counted, _) = snapshot_of(&cut_set(), 1, 1_000, Some(48_210), &[]).unwrap();

        assert_eq!((uncounted.row_count, uncounted.more_rows), (None, true));
        assert_eq!(uncounted.rows.len(), 2);
        assert_eq!((counted.row_count, counted.more_rows), (Some(48_210), false));
    }

    fn traced(name: &str, source: &str) -> ResultColumn {
        ResultColumn::new(name, ColumnType::untyped_text("text"))
            .with_origin(Some(ColumnOrigin::new(TableRef::unqualified("users"), source)))
    }

    // users.email masked as Email, read by `SELECT id, email, phone, notes FROM users`.
    fn ruled_set(revealed: bool) -> ResultSet {
        let columns: Arc<[ResultColumn]> = vec![
            traced("id", "id"),
            traced("email", "email"),
            traced("phone", "phone"),
            traced("notes", "notes"),
        ]
        .into();
        let policy = MaskingPolicy::new([MaskingRule::new(
            "users.email",
            MaskingTarget::Column,
            MaskingStyle::Email,
        )]);
        let masking = GridMasking {
            policy: SharedMaskingPolicy::new(policy),
            named_table: Some("users".to_owned()),
            own_table: None,
            visible: None,
            revealed,
        };
        let store = Arc::new(ResultStore::with_masking(columns, Some(masking)));
        let text = |value: &str| Value::Text(value.to_owned());
        store.append(&[vec![
            text("1"),
            text("ann@example.com"),
            text("+1 555 0100"),
            text("vip"),
        ]]);
        store.finish();
        ResultSet::new(0, store)
    }

    fn cells(snapshot: &Snapshot) -> Vec<&str> {
        snapshot.rows[0].iter().map(|cell| cell.get()).collect()
    }

    #[test]
    fn a_rule_masks_the_share_also_when_the_tab_revealed_its_rows() {
        for revealed in [false, true] {
            let (snapshot, _) = snapshot_of(&ruled_set(revealed), 4, 10, None, &[]).unwrap();

            assert_eq!(
                cells(&snapshot),
                [r#""1""#, r#""a•••@example.com""#, r#""+1 555 0100""#, r#""vip""#],
                "revealed {revealed}"
            );
            let masked: Vec<Option<MaskingStyle>> = snapshot.columns.iter().map(|column| column.masked).collect();
            assert_eq!(masked, [None, Some(MaskingStyle::Email), None, None]);
        }
    }

    #[test]
    fn the_sheet_masks_and_removes_columns_and_never_keeps_a_ruled_one() {
        let mask = |style| ShareColumnChoice::Mask { style };
        let choices = [
            ShareColumnChoice::Remove,
            ShareColumnChoice::Keep,
            mask(MaskStyleTag::LastFour),
            mask(MaskStyleTag::Null),
        ];

        let (snapshot, cut) = snapshot_of(&ruled_set(true), 4, 10, None, &choices).unwrap();

        let names: Vec<&str> = snapshot.columns.iter().map(|column| column.name.as_str()).collect();
        assert_eq!(names, ["email", "phone", "notes"]);
        assert_eq!(cells(&snapshot), [r#""a•••@example.com""#, r#""••••0100""#, "null"]);
        let masked: Vec<Option<MaskingStyle>> = snapshot.columns.iter().map(|column| column.masked).collect();
        assert_eq!(
            masked,
            [
                Some(MaskingStyle::Email),
                Some(MaskingStyle::LastFour),
                Some(MaskingStyle::Null)
            ]
        );
        assert!(!cut);
    }

    #[test]
    fn a_style_that_shows_what_the_rule_hides_leaves_as_full() {
        let choices = [
            ShareColumnChoice::Keep,
            ShareColumnChoice::Mask {
                style: MaskStyleTag::LastFour,
            },
        ];

        let (snapshot, _) = snapshot_of(&ruled_set(false), 2, 10, None, &choices).unwrap();

        assert_eq!(cells(&snapshot), [r#""1""#, r#""••••""#]);
        assert_eq!(snapshot.columns[1].masked, Some(MaskingStyle::Full));
    }
}
