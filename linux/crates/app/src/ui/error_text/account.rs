use tablepro_account::{AccountError, EntitlementError, OfflineFileError};

use crate::i18n::{gettext, gettext_f, ngettext_f};
use crate::services::account_service::AccountStart;

// The OAuth error a person gets by pressing Cancel on the confirmation screen.
const ACCESS_DENIED: &str = "access_denied";

pub fn account_error_message(error: &AccountError) -> String {
    match error {
        AccountError::Unreachable(_) => {
            gettext("TablePro could not reach its account service. Check the internet connection and try again.")
        }
        AccountError::Browser(_) => gettext("TablePro could not open the sign-in page in a web browser."),
        AccountError::SignInTimedOut => {
            gettext("The sign-in was not finished in the browser within 10 minutes. Start it again.")
        }
        AccountError::SignInCanceled => gettext("The sign-in was canceled."),
        AccountError::SignInRefused { error, .. } if error == ACCESS_DENIED => {
            gettext("The sign-in was declined in the browser.")
        }
        AccountError::SignInRefused { error, .. } => {
            gettext_f("The account service refused the sign-in ({code}).", &[("code", error)])
        }
        AccountError::SignedOut => gettext("You were signed out. Sign in again."),
        AccountError::DeviceRevoked => {
            gettext("This computer was removed from your account, so TablePro signed out here.")
        }
        AccountError::DeviceLimitReached { devices } => {
            let count = u32::try_from(devices.len()).unwrap_or(u32::MAX);
            ngettext_f(
                "Your license is in use on {n} other device. Remove one to use it on this computer.",
                "Your license is in use on {n} other devices. Remove one to use it on this computer.",
                count,
                &[("n", &count.to_string())],
            )
        }
        AccountError::OtherAccount => gettext(
            "This file was made for another account. Make one with the account signed in here, or sign out first.",
        ),
        AccountError::Refused { status, code, .. } => {
            share_refusal(error.code()).unwrap_or_else(|| refused_message(*status, code))
        }
        AccountError::RateLimited {
            retry_after: Some(wait),
        } => {
            // Rounded up: until then the account answers the same without asking the service.
            let minutes = u32::try_from(wait.as_millis().div_ceil(60_000))
                .unwrap_or(u32::MAX)
                .max(1);
            ngettext_f(
                "The account service is busy. Try again in {n} minute.",
                "The account service is busy. Try again in {n} minutes.",
                minutes,
                &[("n", &minutes.to_string())],
            )
        }
        AccountError::RateLimited { retry_after: None } => {
            gettext("The account service is busy. Try again in a few minutes.")
        }
        AccountError::Entitlement(error) => entitlement_message(error),
        AccountError::Storage { path, .. } => gettext_f(
            "TablePro could not keep the account’s state in {path}.",
            &[("path", path)],
        ),
        AccountError::Protocol(_) => gettext("TablePro could not read the account service’s answer. Try again later."),
    }
}

pub fn account_unavailable_message(start: &AccountStart) -> Option<String> {
    match start {
        AccountStart::Starting | AccountStart::Ready(_) => None,
        AccountStart::NoMachineId(detail) => Some(gettext_f(
            "TablePro accounts need this computer’s machine ID, which could not be read: {detail}",
            &[("detail", detail)],
        )),
        AccountStart::Misconfigured(detail) => Some(gettext_f(
            "This development build’s account settings are not valid: {detail}",
            &[("detail", detail)],
        )),
        AccountStart::Failed(error) => Some(account_error_message(error)),
    }
}

// The share sheet's own words for a failed create, the share plan's section 6.
pub fn share_error_message(error: &AccountError) -> String {
    match (error, error.code()) {
        (AccountError::SignedOut, _) => gettext("Sign in to your TablePro account to share links."),
        (AccountError::Unreachable(_), _) => offline_message(),
        (AccountError::RateLimited { .. }, _) => gettext("Too many links just now. Try again in a moment."),
        (
            _,
            "account.email_unverified"
            | "account.pro_required"
            | "account.sharing_disabled"
            | "account.team_sharing_disabled"
            | "account.seat_required"
            | "account.share_limit_reached"
            | "account.snapshot_too_large",
        ) => share_refusal(error.code()).unwrap_or_default(),
        _ => gettext("The link couldn’t be created. Try again."),
    }
}

pub fn shared_link_message(error: &AccountError) -> String {
    match (error, error.code()) {
        (AccountError::Unreachable(_), _) => offline_message(),
        (_, "account.not_found") => gettext("This shared link is no longer available."),
        _ => account_error_message(error),
    }
}

fn offline_message() -> String {
    gettext("You appear to be offline. Try again once you’re connected.")
}

fn share_refusal(code: &str) -> Option<String> {
    Some(match code {
        "account.email_unverified" => gettext("Verify your email address to share links."),
        "account.pro_required" => gettext("This option needs TablePro Pro."),
        "account.sharing_disabled" => gettext("Sharing is turned off for this account."),
        "account.team_sharing_disabled" => gettext("Public links are turned off for this team."),
        "account.seat_required" => gettext("A team link needs a seat on the team."),
        "account.share_limit_reached" => {
            gettext("You have reached your plan’s limit of live links. Revoke one to share another.")
        }
        "account.share_revoked" => gettext("This link was revoked."),
        "account.share_removed" => gettext("TablePro removed this link."),
        "account.validation_failed" => {
            gettext("The account service did not accept what was sent. Check the fields and try again.")
        }
        "account.snapshot_too_large" => gettext("This result is too large to share."),
        "account.share_password_required" => gettext("This link is password protected."),
        "account.share_password_wrong" => gettext("That password is not correct."),
        _ => return None,
    })
}

pub fn offline_file_message(error: &OfflineFileError) -> String {
    match error {
        OfflineFileError::Read { .. } => gettext("The offline file could not be read."),
        OfflineFileError::TooLarge { .. } => gettext("This is not an offline file: it is far too large."),
    }
}

fn refused_message(status: u16, code: &str) -> String {
    match code {
        "offline_file_active" => gettext(
            "That device has an offline file that is still valid, so it keeps its license slot until the file expires.",
        ),
        "temporarily_unavailable" => gettext("The account service is busy. Try again in a few minutes."),
        "account_locked" => gettext("Your account is locked. Contact TablePro support."),
        "not_found" => gettext("The account service no longer has it. Refresh and try again."),
        "revoke" => gettext("TablePro signed out here, but could not tell the account service."),
        _ if status >= 500 => gettext_f(
            "The account service had a problem (error {status}). Try again later.",
            &[("status", &status.to_string())],
        ),
        _ => gettext_f(
            "The account service refused the request (error {status}).",
            &[("status", &status.to_string())],
        ),
    }
}

fn entitlement_message(error: &EntitlementError) -> String {
    match error {
        EntitlementError::Machine => {
            gettext("This file was made for another computer. Make one for the machine ID this computer shows.")
        }
        EntitlementError::Expired(at) => gettext_f(
            "It expired on {date}.",
            &[("date", &crate::ui::preferences_dialog::account_view::day(*at))],
        ),
        EntitlementError::NotYetValid(_) => {
            gettext("This computer’s clock is behind. Set the date and time, then try again.")
        }
        EntitlementError::UnknownKey(_) => {
            gettext("This build of TablePro cannot check it: it is signed with a key the build does not have.")
        }
        EntitlementError::Malformed(_)
        | EntitlementError::Algorithm(_)
        | EntitlementError::Type(_)
        | EntitlementError::Signature
        | EntitlementError::Audience => gettext("This is not a TablePro entitlement, or it was changed."),
    }
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    fn refused(status: u16, code: &str) -> AccountError {
        AccountError::Refused {
            status,
            code: code.to_owned(),
            detail: String::new(),
        }
    }

    #[test]
    fn every_error_gets_a_sentence_of_its_own_and_none_the_detail() {
        let errors = [
            AccountError::Unreachable("tcp connect error: secret detail".to_owned()),
            AccountError::Browser("secret detail".to_owned()),
            AccountError::SignInTimedOut,
            AccountError::SignInCanceled,
            AccountError::SignInRefused {
                error: ACCESS_DENIED.to_owned(),
                description: None,
            },
            AccountError::SignInRefused {
                error: "invalid_scope".to_owned(),
                description: Some("secret detail".to_owned()),
            },
            AccountError::SignedOut,
            AccountError::DeviceRevoked,
            AccountError::DeviceLimitReached { devices: Vec::new() },
            AccountError::OtherAccount,
            refused(409, "offline_file_active"),
            AccountError::RateLimited {
                retry_after: Some(std::time::Duration::from_secs(30)),
            },
            AccountError::RateLimited { retry_after: None },
            refused(403, "account_locked"),
            refused(404, "not_found"),
            refused(400, "revoke"),
            refused(503, "unavailable"),
            refused(422, "validation_failed"),
            refused(403, "email_unverified"),
            refused(403, "pro_required"),
            refused(403, "sharing_disabled"),
            refused(403, "team_sharing_disabled"),
            refused(403, "seat_required"),
            refused(409, "share_limit_reached"),
            refused(409, "share_revoked"),
            refused(409, "share_removed"),
            refused(413, "snapshot_too_large"),
            refused(401, "share_password_required"),
            refused(401, "share_password_wrong"),
            AccountError::Entitlement(EntitlementError::Machine),
            AccountError::Entitlement(EntitlementError::Expired(Utc::now())),
            AccountError::Entitlement(EntitlementError::NotYetValid(Utc::now())),
            AccountError::Entitlement(EntitlementError::UnknownKey(None)),
            AccountError::Entitlement(EntitlementError::Signature),
            AccountError::Storage {
                path: "/home/ada/.local/state/tablepro/account.json".to_owned(),
                detail: "secret detail".to_owned(),
            },
            AccountError::Protocol("secret detail".to_owned()),
        ];

        let messages: Vec<String> = errors.iter().map(account_error_message).collect();

        for (error, message) in errors.iter().zip(&messages) {
            assert!(!message.contains("secret detail"), "{error:?}: {message}");
            assert!(message.ends_with('.'), "{error:?}: {message}");
        }
        let distinct: std::collections::HashSet<&String> = messages.iter().collect();
        assert_eq!(distinct.len(), messages.len(), "{messages:#?}");
    }

    #[test]
    fn a_declined_sign_in_reads_as_declined_and_a_device_limit_counts_the_devices() {
        let declined = account_error_message(&AccountError::SignInRefused {
            error: ACCESS_DENIED.to_owned(),
            description: None,
        });
        let other = account_error_message(&AccountError::SignInRefused {
            error: "invalid_scope".to_owned(),
            description: None,
        });

        let device = tablepro_account::Device {
            id: "dev_01".to_owned(),
            machine_id: "0".repeat(64),
            platform: "macos".to_owned(),
            name: "Ada's Mac".to_owned(),
            app_version: "2.0.0".to_owned(),
            os_version: "26.1".to_owned(),
            last_seen_at: Utc::now(),
            licensed_at: Some(Utc::now()),
            offline_until: None,
        };
        let limited = account_error_message(&AccountError::DeviceLimitReached {
            devices: vec![device.clone(), device],
        });

        assert_eq!(declined, "The sign-in was declined in the browser.");
        assert_eq!(other, "The account service refused the sign-in (invalid_scope).");
        assert_eq!(
            limited,
            "Your license is in use on 2 other devices. Remove one to use it on this computer."
        );
    }

    #[test]
    fn a_rate_limit_names_its_wait_in_minutes_rounded_up() {
        let limited =
            |wait: Option<std::time::Duration>| account_error_message(&AccountError::RateLimited { retry_after: wait });
        let seconds = |seconds: u64| Some(std::time::Duration::from_secs(seconds));

        assert_eq!(
            limited(seconds(3600)),
            "The account service is busy. Try again in 60 minutes."
        );
        assert_eq!(
            limited(seconds(61)),
            "The account service is busy. Try again in 2 minutes."
        );
        assert_eq!(
            limited(Some(std::time::Duration::from_millis(500))),
            "The account service is busy. Try again in 1 minute."
        );
        assert_eq!(
            limited(None),
            "The account service is busy. Try again in a few minutes."
        );
    }

    #[test]
    fn a_failed_share_reads_in_the_share_plans_words() {
        let cases = [
            (
                AccountError::SignedOut,
                "Sign in to your TablePro account to share links.",
            ),
            (
                refused(403, "email_unverified"),
                "Verify your email address to share links.",
            ),
            (refused(403, "pro_required"), "This option needs TablePro Pro."),
            (
                refused(403, "sharing_disabled"),
                "Sharing is turned off for this account.",
            ),
            (
                refused(403, "team_sharing_disabled"),
                "Public links are turned off for this team.",
            ),
            (refused(422, "snapshot_too_large"), "This result is too large to share."),
            (
                AccountError::RateLimited { retry_after: None },
                "Too many links just now. Try again in a moment.",
            ),
            (
                AccountError::Unreachable("dns".to_owned()),
                "You appear to be offline. Try again once you’re connected.",
            ),
            (
                refused(422, "validation_failed"),
                "The link couldn’t be created. Try again.",
            ),
            (refused(500, "internal"), "The link couldn’t be created. Try again."),
            (
                AccountError::Protocol("secret detail".to_owned()),
                "The link couldn’t be created. Try again.",
            ),
        ];

        for (error, expected) in cases {
            assert_eq!(share_error_message(&error), expected, "{error:?}");
        }
    }

    #[test]
    fn a_shared_link_that_will_not_open_says_why() {
        assert_eq!(
            shared_link_message(&refused(404, "not_found")),
            "This shared link is no longer available."
        );
        assert_eq!(
            shared_link_message(&refused(401, "share_password_wrong")),
            "That password is not correct."
        );
        assert_eq!(
            shared_link_message(&refused(401, "share_password_required")),
            "This link is password protected."
        );
        assert_eq!(
            shared_link_message(&AccountError::Unreachable("dns".to_owned())),
            "You appear to be offline. Try again once you’re connected."
        );
    }

    #[test]
    fn an_account_that_did_not_start_says_why_and_one_that_did_says_nothing() {
        let missing = account_unavailable_message(&AccountStart::NoMachineId("no /etc/machine-id".to_owned()));

        assert!(missing.is_some_and(|message| message.contains("/etc/machine-id")));
        assert_eq!(account_unavailable_message(&AccountStart::Starting), None);
    }
}
