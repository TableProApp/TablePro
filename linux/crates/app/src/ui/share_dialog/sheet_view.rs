use tablepro_account::{AccountStatus, Share, ShareExpiry, ShareKind, ShareLimits, ShareTeam};
use tablepro_core::secret_scan::SecretHitKind;

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::ui::format::format_thousands;
use crate::ui::preferences_dialog::account_view::day;

const PRO: &str = "pro";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum SheetPage {
    Unavailable(String),
    SignedOut,
    SigningIn,
    Loading,
    Failed(String),
    Unverified,
    Disabled,
    AtLimit,
    Form,
    // Whether the link reached the clipboard, and whether the server's column cap cut the result.
    Created {
        url: String,
        copied: bool,
        columns_truncated: bool,
    },
}

// Who a link belongs to: the account, or one of the teams it holds a seat in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ShareTarget {
    pub team: Option<String>,
    pub name: String,
    pub subtitle: String,
    // False for a team that turned public links off.
    pub enabled: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ExpiryChoice {
    pub expiry: ShareExpiry,
    // False for an expiry only Pro has, which shows with a Pro tag.
    pub allowed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LiveLinkRow {
    pub id: String,
    pub title: String,
    pub subtitle: String,
    // It does not resolve until the account or the team turns sharing on again.
    pub suspended: bool,
}

// An offline file unlocks features but signs no request.
pub(crate) fn signed_in(status: &AccountStatus) -> bool {
    matches!(status, AccountStatus::SignedIn(_))
}

// A team link counts against the team's limit, never the account's.
pub(crate) fn page_for(limits: &ShareLimits, team: Option<&ShareTeam>) -> SheetPage {
    let at_limit = team.map_or_else(|| limits.at_limit(), ShareTeam::at_limit);
    if !limits.email_verified {
        SheetPage::Unverified
    } else if limits.sharing_disabled {
        SheetPage::Disabled
    } else if at_limit {
        SheetPage::AtLimit
    } else {
        SheetPage::Form
    }
}

// The team a choice names, when the plan still lists it and lets it share.
pub(crate) fn chosen_team<'a>(limits: &'a ShareLimits, team: Option<&str>) -> Option<&'a ShareTeam> {
    let team = team?;
    limits.teams.iter().find(|known| known.id == team && known.public_links)
}

// Personal first, then each team, a team that turned public links off listed but not offered.
pub(crate) fn share_targets(limits: &ShareLimits) -> Vec<ShareTarget> {
    let mut targets = vec![ShareTarget {
        team: None,
        name: gettext("Personal"),
        subtitle: String::new(),
        enabled: true,
    }];
    targets.extend(limits.teams.iter().map(|team| ShareTarget {
        team: Some(team.id.clone()),
        name: team.name.replace('\0', ""),
        subtitle: match team.public_links {
            true => team_links(team),
            false => gettext("Public links are off for this team."),
        },
        enabled: team.public_links,
    }));
    targets
}

fn team_links(team: &ShareTeam) -> String {
    ngettext_f(
        "{live} of {limit} link",
        "{live} of {limit} links",
        team.live_limit,
        &[
            ("live", &format_thousands(team.live)),
            ("limit", &format_thousands(team.live_limit)),
        ],
    )
}

pub(crate) fn is_pro(limits: &ShareLimits) -> bool {
    limits.plan == PRO
}

pub(crate) fn title(kind: ShareKind) -> String {
    match kind {
        ShareKind::Query => gettext("Share Query"),
        ShareKind::Result => gettext("Share Result"),
    }
}

pub(crate) fn footer(limits: &ShareLimits, team: Option<&ShareTeam>) -> String {
    if let Some(team) = team {
        return gettext_f(
            "{team} · {links}",
            &[("team", &team.name.replace('\0', "")), ("links", &team_links(team))],
        );
    }
    let live = format_thousands(limits.live);
    match is_pro(limits) {
        true => ngettext_f(
            "Pro · {live} link",
            "Pro · {live} links",
            limits.live,
            &[("live", &live)],
        ),
        false => ngettext_f(
            "Free · {live} of {limit} link · first {max_rows} rows",
            "Free · {live} of {limit} links · first {max_rows} rows",
            limits.live_limit,
            &[
                ("live", &live),
                ("limit", &format_thousands(limits.live_limit)),
                ("max_rows", &format_thousands(limits.max_rows)),
            ],
        ),
    }
}

// The plan's expiries, then Never for a plan without it, which only Pro may pick.
pub(crate) fn expiry_choices(limits: &ShareLimits) -> Vec<ExpiryChoice> {
    let mut choices: Vec<ExpiryChoice> = ShareExpiry::ALL
        .into_iter()
        .filter(|expiry| limits.expiries.contains(expiry))
        .map(|expiry| ExpiryChoice { expiry, allowed: true })
        .collect();
    if !limits.expiries.contains(&ShareExpiry::Never) {
        choices.push(ExpiryChoice {
            expiry: ShareExpiry::Never,
            allowed: false,
        });
    }
    choices
}

pub(crate) fn default_expiry(limits: &ShareLimits) -> ShareExpiry {
    limits
        .default_expiry
        .filter(|expiry| limits.expiries.contains(expiry))
        .or_else(|| limits.expiries.last().copied())
        .unwrap_or(ShareExpiry::ThirtyDays)
}

pub(crate) fn expiry_label(expiry: ShareExpiry) -> String {
    match expiry {
        ShareExpiry::OneDay => gettext("1 day"),
        ShareExpiry::SevenDays => gettext("7 days"),
        ShareExpiry::ThirtyDays => gettext("30 days"),
        ShareExpiry::Never => gettext("Never"),
    }
}

pub(crate) fn cap_note(total: u64, max_rows: u64) -> Option<String> {
    (total > max_rows).then(|| {
        gettext_f(
            "Shares the first {shared} of {total} rows.",
            &[
                ("shared", &format_thousands(max_rows)),
                ("total", &format_thousands(total)),
            ],
        )
    })
}

// A downgrade can leave more live links than the plan allows, so the count and the limit are both named.
pub(crate) fn at_limit_message(limits: &ShareLimits, team: Option<&ShareTeam>) -> String {
    if let Some(team) = team {
        let (live, limit, name) = (
            format_thousands(team.live),
            format_thousands(team.live_limit),
            team.name.replace('\0', ""),
        );
        return ngettext_f(
            "{team} has {live} live link. The team allows {limit}. Revoke one to share another.",
            "{team} has {live} live links. The team allows {limit}. Revoke one to share another.",
            team.live,
            &[("team", &name), ("live", &live), ("limit", &limit)],
        );
    }
    let (live, limit) = (format_thousands(limits.live), format_thousands(limits.live_limit));
    let args = [("live", live.as_str()), ("limit", limit.as_str())];
    match is_pro(limits) {
        true => ngettext_f(
            "You have {live} live link. Pro allows {limit}. Revoke one to share another.",
            "You have {live} live links. Pro allows {limit}. Revoke one to share another.",
            limits.live,
            &args,
        ),
        false => ngettext_f(
            "You have {live} live link. Free allows {limit}. Revoke one to share another.",
            "You have {live} live links. Free allows {limit}. Revoke one to share another.",
            limits.live,
            &args,
        ),
    }
}

// Pro's own cap, and a team's, need no pitch.
pub(crate) fn at_limit_upsell(limits: &ShareLimits, team: Option<&ShareTeam>) -> Option<String> {
    (!is_pro(limits) && team.is_none()).then(|| gettext("Pro allows up to 1,000."))
}

// The server takes the first `max_columns` columns of a result and leaves the rest out.
pub(crate) fn column_note(columns_cut: bool, max_columns: u64) -> Option<String> {
    columns_cut.then(|| {
        ngettext_f(
            "Shares the first {count} column.",
            "Shares the first {count} columns.",
            max_columns,
            &[("count", &format_thousands(max_columns))],
        )
    })
}

// macOS words it the same.
pub(crate) fn no_columns_note() -> String {
    gettext("Keep or mask at least one column to share.")
}

pub(crate) fn columns_left_out(max_columns: u64) -> String {
    ngettext_f(
        "The link shares the first {count} column.",
        "The link shares the first {count} columns.",
        max_columns,
        &[("count", &format_thousands(max_columns))],
    )
}

// Oldest first, so the link that has been out longest is the first offered.
pub(crate) fn live_link_rows(shares: &[Share]) -> Vec<LiveLinkRow> {
    let mut live: Vec<&Share> = shares.iter().filter(|share| share.is_live()).collect();
    live.sort_by_key(|share| share.created_at);
    live.into_iter()
        .map(|share| LiveLinkRow {
            id: share.id.clone(),
            title: link_title(share),
            subtitle: link_subtitle(share),
            suspended: share.suspended,
        })
        .collect()
}

// GTK refuses text with a NUL in it, which the server passes through from whoever named the link.
fn link_title(share: &Share) -> String {
    let title = share.title.replace('\0', "");
    match (title.trim(), share.kind.as_str()) {
        ("", "result") => gettext("Shared result"),
        ("", _) => gettext("Shared query"),
        (title, _) => title.to_owned(),
    }
}

// A suspended link says so first, where a screen reader reads it with the row.
fn link_subtitle(share: &Share) -> String {
    let created = gettext_f("Shared {date}", &[("date", &day(share.created_at))]);
    let expires = match share.expires_at {
        Some(at) => gettext_f("Expires {date}", &[("date", &day(at))]),
        None => gettext("Never expires"),
    };
    let suspended = share.suspended.then(|| gettext("Suspended"));
    suspended
        .into_iter()
        .chain([created, expires])
        .collect::<Vec<_>>()
        .join(" · ")
}

// Hidden SQL reaches no viewer, so only the columns warn then.
pub(crate) fn secret_warnings(kinds: &[SecretHitKind], columns: &[String], hide_sql: bool) -> Vec<String> {
    let mut warnings: Vec<String> = match hide_sql {
        true => Vec::new(),
        false => kinds
            .iter()
            .map(|kind| {
                gettext_f(
                    "This query may contain a secret ({kind}). Anyone with the link can read it.",
                    &[("kind", &secret_kind(*kind))],
                )
            })
            .collect(),
    };
    if !columns.is_empty() {
        warnings.push(gettext_f(
            "Some columns may hold secrets: {names}.",
            &[("names", &columns.join(", "))],
        ));
    }
    warnings
}

fn secret_kind(kind: SecretHitKind) -> String {
    match kind {
        SecretHitKind::AwsAccessKey => gettext("an AWS access key"),
        SecretHitKind::PrivateKey => gettext("a private key"),
        SecretHitKind::JsonWebToken => gettext("a JSON Web Token"),
        SecretHitKind::GitHubToken => gettext("a GitHub token"),
        SecretHitKind::SlackToken => gettext("a Slack token"),
        SecretHitKind::StripeKey => gettext("a Stripe key"),
        SecretHitKind::GoogleApiKey => gettext("a Google API key"),
        SecretHitKind::UrlCredentials => gettext("a password in a URL"),
        SecretHitKind::AssignedSecret => gettext("a password or token"),
    }
}

#[cfg(test)]
mod tests {
    use chrono::{TimeDelta, Utc};

    use super::*;

    fn limits(plan: &str, live: u64) -> ShareLimits {
        let pro = plan == PRO;
        ShareLimits {
            plan: plan.to_owned(),
            live,
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
            teams: Vec::new(),
        }
    }

    fn team(id: &str, live: u64, public_links: bool) -> ShareTeam {
        ShareTeam {
            id: id.to_owned(),
            name: format!("Team {id}"),
            live,
            live_limit: 1_000,
            public_links,
        }
    }

    fn share(id: &str, title: &str, state: &str, created_days_ago: i64) -> Share {
        let now = Utc::now();
        Share {
            id: id.to_owned(),
            kind: "result".to_owned(),
            scope: "account".to_owned(),
            team_id: None,
            title: title.to_owned(),
            note: String::new(),
            dialect: String::new(),
            sql: None,
            has_snapshot: true,
            row_count: Some(1),
            truncated: Some(false),
            hide_sql: false,
            allow_download: true,
            has_password: false,
            state: state.to_owned(),
            removed_reason: None,
            suspended: false,
            suspended_by: None,
            view_count: 0,
            created_at: now - TimeDelta::days(created_days_ago),
            updated_at: now,
            expires_at: None,
            revoked_at: None,
            removed_at: None,
            url: None,
        }
    }

    #[test]
    fn the_page_follows_the_accounts_state_in_the_plans_order() {
        let mut unverified = limits("free", 5);
        unverified.email_verified = false;
        unverified.sharing_disabled = true;
        let mut disabled = limits("free", 5);
        disabled.sharing_disabled = true;

        assert_eq!(page_for(&unverified, None), SheetPage::Unverified);
        assert_eq!(page_for(&disabled, None), SheetPage::Disabled);
        assert_eq!(page_for(&limits("free", 5), None), SheetPage::AtLimit);
        assert_eq!(page_for(&limits("free", 4), None), SheetPage::Form);
        assert_eq!(page_for(&limits("pro", 5), None), SheetPage::Form);
    }

    #[test]
    fn the_footer_names_the_plan_its_links_and_free_rows() {
        assert_eq!(
            footer(&limits("free", 3), None),
            "Free · 3 of 5 links · first 1,000 rows"
        );
        assert_eq!(footer(&limits("pro", 12), None), "Pro · 12 links");
        assert_eq!(footer(&limits("pro", 1), None), "Pro · 1 link");
    }

    #[test]
    fn free_sees_never_as_a_pro_expiry_and_defaults_to_thirty_days() {
        let free = limits("free", 0);
        let pro = limits("pro", 0);

        let free_choices = expiry_choices(&free);

        assert_eq!(free_choices.len(), 4);
        assert!(free_choices[..3].iter().all(|choice| choice.allowed));
        assert_eq!(
            free_choices[3],
            ExpiryChoice {
                expiry: ShareExpiry::Never,
                allowed: false
            }
        );
        assert!(expiry_choices(&pro).iter().all(|choice| choice.allowed));
        assert_eq!(default_expiry(&free), ShareExpiry::ThirtyDays);
        assert_eq!(default_expiry(&pro), ShareExpiry::Never);
    }

    #[test]
    fn a_default_the_plan_does_not_offer_falls_back_to_its_longest() {
        let mut odd = limits("free", 0);
        odd.default_expiry = Some(ShareExpiry::Never);

        assert_eq!(default_expiry(&odd), ShareExpiry::ThirtyDays);
        odd.expiries.clear();
        assert_eq!(default_expiry(&odd), ShareExpiry::ThirtyDays);
    }

    #[test]
    fn only_a_result_past_the_plans_rows_gets_the_cap_note() {
        assert_eq!(
            cap_note(48_210, 1_000).as_deref(),
            Some("Shares the first 1,000 of 48,210 rows.")
        );
        assert_eq!(cap_note(1_000, 1_000), None);
    }

    #[test]
    fn at_the_limit_free_hears_about_pro_and_pro_does_not() {
        assert_eq!(
            at_limit_message(&limits("free", 5), None),
            "You have 5 live links. Free allows 5. Revoke one to share another."
        );
        assert_eq!(
            at_limit_message(&limits("free", 12), None),
            "You have 12 live links. Free allows 5. Revoke one to share another.",
            "a downgrade left more links than Free allows"
        );
        assert_eq!(
            at_limit_upsell(&limits("free", 5), None).as_deref(),
            Some("Pro allows up to 1,000.")
        );
        assert_eq!(
            at_limit_message(&limits("pro", 1_000), None),
            "You have 1,000 live links. Pro allows 1,000. Revoke one to share another."
        );
        assert_eq!(at_limit_upsell(&limits("pro", 1_000), None), None);
    }

    #[test]
    fn live_links_list_oldest_first_and_only_live_ones() {
        let mut suspended = share("shr_new", "N\0ew", "live", 1);
        suspended.suspended = true;
        suspended.suspended_by = Some("team".to_owned());
        let shares = [
            suspended,
            share("shr_gone", "Gone", "revoked", 9),
            share("shr_old", "", "live", 5),
        ];

        let rows = live_link_rows(&shares);

        assert_eq!(
            rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
            ["shr_old", "shr_new"]
        );
        assert_eq!(rows[0].title, "Shared result");
        assert_eq!(rows[1].title, "New");
        assert!(rows[1].suspended);
        assert!(rows[1].subtitle.starts_with("Suspended · "), "{}", rows[1].subtitle);
        assert!(!rows[0].suspended);
        assert!(rows[0].subtitle.ends_with("Never expires"), "{}", rows[0].subtitle);
    }

    #[test]
    fn secret_warnings_name_each_kind_and_hidden_sql_drops_them() {
        let kinds = [SecretHitKind::AwsAccessKey, SecretHitKind::UrlCredentials];
        let columns = ["password".to_owned(), "ssn".to_owned()];

        let shown = secret_warnings(&kinds, &columns, false);
        let hidden = secret_warnings(&kinds, &columns, true);

        assert_eq!(
            shown,
            [
                "This query may contain a secret (an AWS access key). Anyone with the link can read it.",
                "This query may contain a secret (a password in a URL). Anyone with the link can read it.",
                "Some columns may hold secrets: password, ssn.",
            ]
        );
        assert_eq!(hidden, ["Some columns may hold secrets: password, ssn."]);
        assert!(secret_warnings(&[], &[], false).is_empty());
    }

    #[test]
    fn only_a_signed_in_account_can_share() {
        assert!(!signed_in(&AccountStatus::SignedOut));
    }

    #[test]
    fn personal_comes_first_and_a_team_without_public_links_is_listed_but_not_offered() {
        let mut pro = limits("pro", 3);
        pro.teams = vec![team("team_a", 2, true), team("team_b", 0, false)];

        let targets = share_targets(&pro);

        assert_eq!(
            targets
                .iter()
                .map(|target| (target.team.as_deref(), target.enabled))
                .collect::<Vec<_>>(),
            [(None, true), (Some("team_a"), true), (Some("team_b"), false)]
        );
        assert_eq!(targets[0].name, "Personal");
        assert_eq!(targets[1].subtitle, "2 of 1,000 links");
        assert_eq!(targets[2].subtitle, "Public links are off for this team.");
        assert_eq!(
            chosen_team(&pro, Some("team_b")),
            None,
            "a team without public links is never chosen"
        );
        assert_eq!(chosen_team(&pro, Some("team_gone")), None);
        assert!(share_targets(&limits("free", 0)).len() == 1);
    }

    #[test]
    fn a_team_choice_counts_against_the_teams_own_limit() {
        let mut pro = limits("pro", 1_000);
        pro.teams = vec![team("team_a", 1_000, true), team("team_b", 4, true)];
        let full = chosen_team(&pro, Some("team_a"));
        let room = chosen_team(&pro, Some("team_b"));

        assert_eq!(
            page_for(&pro, room),
            SheetPage::Form,
            "the account's own limit counts no team link"
        );
        assert_eq!(page_for(&pro, full), SheetPage::AtLimit);
        assert_eq!(footer(&pro, room), "Team team_b · 4 of 1,000 links");
        assert_eq!(
            at_limit_message(&pro, full),
            "Team team_a has 1,000 live links. The team allows 1,000. Revoke one to share another."
        );
        assert_eq!(at_limit_upsell(&limits("free", 5), full), None);
    }

    #[test]
    fn only_a_result_past_the_column_cap_gets_the_column_note() {
        assert_eq!(column_note(true, 100).as_deref(), Some("Shares the first 100 columns."));
        assert_eq!(column_note(false, 100), None);
        assert_eq!(columns_left_out(100), "The link shares the first 100 columns.");
    }
}
