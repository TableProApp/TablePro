use std::num::NonZeroU64;

use tablepro_cloud_api::answer_error;

use super::{Account, Call, Session};
use crate::account_error::AccountError;
use crate::profile::TeamMember;

const MEMBER_PAGE: NonZeroU64 = NonZeroU64::MIN.saturating_add(199);
// A team holds at most 5,000 key holders (core ADR 0051, Limits), 25 pages of the document's largest.
const MEMBER_PAGES: usize = 25;

impl Account {
    // The server serves the list to the team's owners and admins only, and refuses anyone else.
    pub async fn team_members(&self, team_id: &str) -> Result<Vec<TeamMember>, AccountError> {
        let mut session = self.inner.session.lock().await;
        let fetched = self.fetch_team_members(&mut session, team_id).await;
        self.ended_by(&mut session, fetched).await
    }

    async fn fetch_team_members(&self, session: &mut Session, team_id: &str) -> Result<Vec<TeamMember>, AccountError> {
        session.waited(Call::TeamMembers)?;
        let api = self.api(self.bearer(session, false).await?);
        let mut members = Vec::new();
        let mut cursor = None;
        for _ in 0..MEMBER_PAGES {
            self.reachable()?;
            let page = match api.list_team_members(team_id, cursor.as_deref(), Some(MEMBER_PAGE)).await {
                Ok(answer) => answer.into_inner(),
                Err(error) => return session.answered(Call::TeamMembers, Err(answer_error(error).await.into())),
            };
            members.extend(page.data.into_iter().map(TeamMember::from));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        Ok(members)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use chrono::Utc;
    use tokio::sync::watch;

    use super::super::tests::{Keyring, NoBrowser, TOKENS, cloud, entitlement, keep, stub_settings};
    use super::*;
    use crate::account_status::AccountStatus;

    const TEAM: &str = "team_01k8d6wk00f8xsr79e7x052rkk";

    fn member(account: &str, email: &str, name: Option<&str>) -> String {
        let name = name.map_or(String::new(), |name| format!(r#","name":"{name}""#));
        format!(
            r#"{{"id":"mem_{account}","account_id":"{account}","email":"{email}"{name},"role":"member","has_seat":true,"joined_at":"2026-11-01T00:00:00Z"}}"#
        )
    }

    async fn signed_in(dir: &std::path::Path, endpoints: crate::account_settings::Endpoints) -> Account {
        keep(dir, Some(entitlement(Utc::now()))).await;
        let account = Account::new(
            stub_settings(dir, endpoints),
            Keyring::holding(Some("refresh")),
            Arc::new(NoBrowser),
            watch::Sender::new(AccountStatus::SignedOut),
        )
        .expect("an account");
        account.restore().await;
        account
    }

    #[tokio::test]
    async fn every_page_of_the_member_list_is_read_with_each_name_and_email() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let asked = Arc::new(Mutex::new(Vec::new()));
        let log = asked.clone();
        let first = format!(
            r#"{{"data":[{}],"next_cursor":"page2"}}"#,
            member("acct_01k8d6wk00f8xsr79e7x052aaa", "ana@example.com", Some("Ana"))
        );
        let second = format!(
            r#"{{"data":[{}]}}"#,
            member("acct_01k8d6wk00f8xsr79e7x052bbb", "bo@example.com", Some("  "))
        );
        let endpoints = cloud(move |method, path| {
            log.lock().expect("the log").push(path.to_owned());
            match (method, path.split('?').next().unwrap_or_default()) {
                ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                ("GET", "/v2/teams/team_01k8d6wk00f8xsr79e7x052rkk/members") if path.contains("cursor=page2") => {
                    (200, second.clone())
                }
                ("GET", "/v2/teams/team_01k8d6wk00f8xsr79e7x052rkk/members") => (200, first.clone()),
                _ => (404, String::new()),
            }
        });
        let account = signed_in(dir.path(), endpoints).await;

        let members = account.team_members(TEAM).await.expect("the members");

        assert_eq!(
            members,
            vec![
                TeamMember {
                    account_id: "acct_01k8d6wk00f8xsr79e7x052aaa".to_owned(),
                    email: "ana@example.com".to_owned(),
                    name: Some("Ana".to_owned()),
                    role: "member".to_owned(),
                },
                TeamMember {
                    account_id: "acct_01k8d6wk00f8xsr79e7x052bbb".to_owned(),
                    email: "bo@example.com".to_owned(),
                    name: None,
                    role: "member".to_owned(),
                },
            ]
        );
        let pages: Vec<String> = asked
            .lock()
            .expect("the log")
            .iter()
            .filter(|path| path.contains("/members"))
            .cloned()
            .collect();
        assert_eq!(pages.len(), 2, "{pages:?}");
        assert!(pages.iter().all(|path| path.contains("limit=200")), "{pages:?}");
    }

    #[tokio::test]
    async fn a_member_who_does_not_manage_the_team_is_refused_the_list() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let endpoints = cloud(move |method, path| match (method, path.split('?').next().unwrap_or_default()) {
            ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
            ("GET", "/v2/teams/team_01k8d6wk00f8xsr79e7x052rkk/members") => (
                403,
                r#"{"type":"about:blank","title":"Forbidden","status":403,"code":"forbidden"}"#.to_owned(),
            ),
            _ => (404, String::new()),
        });
        let account = signed_in(dir.path(), endpoints).await;

        let members = account.team_members(TEAM).await;

        assert!(members.is_err(), "{members:?}");
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedIn(_)));
    }
}
