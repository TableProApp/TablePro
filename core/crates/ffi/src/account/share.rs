use std::sync::Arc;

use chrono::{DateTime, Utc};
use secrecy::SecretString;
use tablepro_account::{CreatedShare, Share, ShareExpiry, ShareKind, ShareLimits, SharePage, ShareRequest, SharedLink};
use tablepro_core::column::ResultColumn;
use tablepro_core::export::{Snapshot, build_snapshot};

use super::account_service::AccountService;
use crate::error::CoreError;
use crate::export::held_row;
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
    pub expiries: Vec<ShareExpiryTag>,
    pub default_expiry: Option<ShareExpiryTag>,
    pub password: bool,
    pub disable_download: bool,
    pub team: bool,
    pub email_verified: bool,
    pub sharing_disabled: bool,
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
    pub view_count: u64,
    pub created_at_secs: i64,
    pub updated_at_secs: i64,
    pub expires_at_secs: Option<i64>,
    pub revoked_at_secs: Option<i64>,
    pub removed_at_secs: Option<i64>,
    pub url: Option<String>,
    // The team or staff turned sharing off: the state stays, the link does not resolve and has no url.
    pub suspended: bool,
    // "account", "team" or "team_deleted" while suspended.
    pub suspended_by: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreatedShareInfo {
    pub share: ShareInfo,
    pub url: String,
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
    pub async fn create_share(
        &self,
        request: ShareRequestArg,
        result: Option<Arc<ResultSet>>,
        visible_columns: u32,
        max_rows: u32,
        total_rows: Option<u64>,
    ) -> Result<CreatedShareInfo, CoreError> {
        let account = self.account.clone();
        let tasks = self.tasks.clone();
        on_runtime(&self.tasks, async move {
            let snapshot = match (request.kind, result) {
                (ShareKindTag::Query, _) => None,
                (ShareKindTag::Result, None) => {
                    return Err(CoreError::failed(
                        "ffi.share_needs_result",
                        "a result share needs its result set",
                    ));
                }
                (ShareKindTag::Result, Some(set)) => {
                    let built = tasks
                        .spawn_blocking_task(move || snapshot_of(&set, visible_columns, max_rows, total_rows))
                        .await
                        .map_err(|failure| CoreError::failed("ffi.panicked", failure.to_string()))??;
                    Some(built)
                }
            };
            let created = account.create_share(share_request(request, snapshot)).await?;
            Ok(created.into())
        })
        .await
    }

    // The account's own links, newest first, without their SQL.
    pub async fn list_shares(&self, live_only: bool, cursor: Option<String>) -> Result<SharePageInfo, CoreError> {
        let account = self.account.clone();
        on_runtime(&self.tasks, async move {
            Ok(account.list_shares(live_only, cursor.as_deref()).await?.into())
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

fn snapshot_of(
    set: &ResultSet,
    visible_columns: u32,
    max_rows: u32,
    total_rows: Option<u64>,
) -> Result<Snapshot, CoreError> {
    // A set still reading would share the rows held so far as if they were all of them.
    if !set.is_finished() {
        return Err(CoreError::failed("ffi.share_unfinished", "the rows are still arriving"));
    }
    let held = set.result_columns();
    let visible = usize::try_from(visible_columns).unwrap_or(usize::MAX).min(held.len());
    let columns: Vec<ResultColumn> = held.iter().take(visible).cloned().collect();
    let held = set.row_count();
    let taken = held.min(u64::from(max_rows));
    let rows = (0..taken).map(|row| held_row(set, row, &columns));
    let total = total_rows.map_or(held, |total| total.max(held));
    Ok(build_snapshot(
        &columns,
        rows,
        total,
        usize::try_from(max_rows).unwrap_or(usize::MAX),
    ))
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
            expiries: limits.expiries.into_iter().map(ShareExpiryTag::from).collect(),
            default_expiry: limits.default_expiry.map(ShareExpiryTag::from),
            password: limits.password,
            disable_download: limits.disable_download,
            team: limits.team,
            email_verified: limits.email_verified,
            sharing_disabled: limits.sharing_disabled,
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
            view_count: share.view_count,
            created_at_secs: seconds(share.created_at),
            updated_at_secs: seconds(share.updated_at),
            expires_at_secs: share.expires_at.map(seconds),
            revoked_at_secs: share.revoked_at.map(seconds),
            removed_at_secs: share.removed_at.map(seconds),
            url: share.url,
            suspended: share.suspended,
            suspended_by: share.suspended_by,
        }
    }
}

impl From<CreatedShare> for CreatedShareInfo {
    fn from(created: CreatedShare) -> Self {
        Self {
            share: created.share.into(),
            url: created.url,
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
