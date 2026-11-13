use chrono::{DateTime, Utc};
use tablepro_account::{AccountStatus, Share, ShareExpiry, ShareKind, ShareLimits};
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
    Created(String),
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
}

// An offline file unlocks features but signs no request.
pub(crate) fn signed_in(status: &AccountStatus) -> bool {
    matches!(status, AccountStatus::SignedIn(_))
}

pub(crate) fn page_for(limits: &ShareLimits) -> SheetPage {
    if !limits.email_verified {
        SheetPage::Unverified
    } else if limits.sharing_disabled {
        SheetPage::Disabled
    } else if limits.at_limit() {
        SheetPage::AtLimit
    } else {
        SheetPage::Form
    }
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

pub(crate) fn footer(limits: &ShareLimits) -> String {
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

pub(crate) fn at_limit_message(limits: &ShareLimits) -> String {
    let limit = format_thousands(limits.live_limit);
    match is_pro(limits) {
        true => gettext_f(
            "You have {limit} live links, the Pro limit. Revoke one to share another.",
            &[("limit", &limit)],
        ),
        false => gettext_f(
            "You have {limit} live links, the Free limit. Revoke one to share another.",
            &[("limit", &limit)],
        ),
    }
}

// Pro's own cap needs no pitch.
pub(crate) fn at_limit_upsell(limits: &ShareLimits) -> Option<String> {
    (!is_pro(limits)).then(|| gettext("Pro allows up to 1,000."))
}

// Oldest first, so the link that has been out longest is the first offered.
pub(crate) fn live_link_rows(shares: &[Share]) -> Vec<LiveLinkRow> {
    let mut live: Vec<&Share> = shares.iter().filter(|share| share.is_live()).collect();
    live.sort_by_key(|share| share.created_at);
    live.into_iter()
        .map(|share| LiveLinkRow {
            id: share.id.clone(),
            title: link_title(share),
            subtitle: link_subtitle(share.created_at, share.expires_at),
        })
        .collect()
}

fn link_title(share: &Share) -> String {
    match (share.title.trim(), share.kind.as_str()) {
        ("", "result") => gettext("Shared result"),
        ("", _) => gettext("Shared query"),
        (title, _) => title.to_owned(),
    }
}

fn link_subtitle(created: DateTime<Utc>, expires: Option<DateTime<Utc>>) -> String {
    let created = gettext_f("Shared {date}", &[("date", &day(created))]);
    let expires = match expires {
        Some(at) => gettext_f("Expires {date}", &[("date", &day(at))]),
        None => gettext("Never expires"),
    };
    [created, expires].join(" · ")
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
    use chrono::TimeDelta;

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

        assert_eq!(page_for(&unverified), SheetPage::Unverified);
        assert_eq!(page_for(&disabled), SheetPage::Disabled);
        assert_eq!(page_for(&limits("free", 5)), SheetPage::AtLimit);
        assert_eq!(page_for(&limits("free", 4)), SheetPage::Form);
        assert_eq!(page_for(&limits("pro", 5)), SheetPage::Form);
    }

    #[test]
    fn the_footer_names_the_plan_its_links_and_free_rows() {
        assert_eq!(footer(&limits("free", 3)), "Free · 3 of 5 links · first 1,000 rows");
        assert_eq!(footer(&limits("pro", 12)), "Pro · 12 links");
        assert_eq!(footer(&limits("pro", 1)), "Pro · 1 link");
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
            at_limit_message(&limits("free", 5)),
            "You have 5 live links, the Free limit. Revoke one to share another."
        );
        assert_eq!(
            at_limit_upsell(&limits("free", 5)).as_deref(),
            Some("Pro allows up to 1,000.")
        );
        assert_eq!(
            at_limit_message(&limits("pro", 1_000)),
            "You have 1,000 live links, the Pro limit. Revoke one to share another."
        );
        assert_eq!(at_limit_upsell(&limits("pro", 1_000)), None);
    }

    #[test]
    fn live_links_list_oldest_first_and_only_live_ones() {
        let shares = [
            share("shr_new", "New", "live", 1),
            share("shr_gone", "Gone", "revoked", 9),
            share("shr_old", "", "live", 5),
        ];

        let rows = live_link_rows(&shares);

        assert_eq!(
            rows.iter().map(|row| row.id.as_str()).collect::<Vec<_>>(),
            ["shr_old", "shr_new"]
        );
        assert_eq!(rows[0].title, "Shared result");
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
}
