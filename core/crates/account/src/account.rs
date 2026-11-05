use std::collections::HashMap;
use std::num::NonZeroU64;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use chrono::{DateTime, TimeDelta, Utc};
use secrecy::{ExposeSecret as _, SecretString};
use tokio::sync::{Mutex, watch};
use tokio::time::Instant;

use crate::account_error::AccountError;
use crate::account_file::{self, AccountFile};
use crate::account_settings::AccountSettings;
use crate::account_status::{AccountStatus, EntitlementProblem, SignedIn};
use crate::browser::BrowserLauncher;
use crate::cloud_api::{Bearer, answer_error, v2};
use crate::entitlement::{Entitlement, EntitlementError};
use crate::loopback::{Callback, Loopback};
use crate::machine_id::MachineId;
use crate::oauth::{OAuth, Tokens};
use crate::profile::{Device, Profile};
use crate::token_vault::RefreshTokenVault;

// The server forgets an unanswered sign-in after 10 minutes.
const SIGN_IN_TIMEOUT: Duration = Duration::from_secs(10 * 60);
const ACCESS_TOKEN_MARGIN: TimeDelta = TimeDelta::seconds(60);
pub const REFRESH_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
pub const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 60);
// How soon after a wake a refresh that came due during the sleep runs.
const WALL_CLOCK_CHECK: Duration = Duration::from_secs(5 * 60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const FIELD_CHARACTERS: usize = 100;
const DEVICE_PAGE: NonZeroU64 = NonZeroU64::MIN.saturating_add(199);
// A server that keeps answering with a cursor cannot hold the session forever.
const DEVICE_PAGES: usize = 10;

// Every operation holds the session, so a token refresh is single-flight.
#[derive(Clone)]
pub struct Account {
    inner: Arc<Inner>,
}

struct Inner {
    settings: AccountSettings,
    http: reqwest::Client,
    oauth: OAuth,
    vault: Arc<dyn RefreshTokenVault>,
    browser: Arc<dyn BrowserLauncher>,
    session: Mutex<Session>,
    status: watch::Sender<AccountStatus>,
    // When run() refreshes next. Every refresh moves it, whatever asked for it.
    due: watch::Sender<Instant>,
    // Bumped by each sign-in and sign-out, so an earlier sign-in still out cannot commit over them.
    attempts: AtomicU64,
}

#[derive(Default)]
struct Session {
    refresh: Option<SecretString>,
    // On the wall clock: Instant stops while the machine sleeps, so a token would outlive its expiry.
    access: Option<(SecretString, DateTime<Utc>)>,
    device_id: Option<String>,
    // The account the sign-in is of: its last entitlement's, or what /v2/me answered.
    account_id: Option<String>,
    remembered: bool,
    // Until when each call a 429 answered waits, by its Retry-After, on the wall clock as the access token's expiry is.
    held: HashMap<Call, DateTime<Utc>>,
}

#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Call {
    Token,
    Register,
    Entitlement,
    Profile,
    Devices,
    RemoveDevice,
}

impl Session {
    // Until a 429's Retry-After passes, the call answers the 429 again without a request.
    fn waited(&self, call: Call) -> Result<(), AccountError> {
        let now = Utc::now();
        match self.held.get(&call) {
            Some(until) if *until > now => Err(AccountError::RateLimited {
                retry_after: Some((*until - now).to_std().unwrap_or_default()),
            }),
            _ => Ok(()),
        }
    }

    fn answered<T>(&mut self, call: Call, answer: Result<T, AccountError>) -> Result<T, AccountError> {
        match &answer {
            Err(AccountError::RateLimited {
                retry_after: Some(retry_after),
            }) => {
                let until = TimeDelta::from_std(*retry_after)
                    .ok()
                    .and_then(|wait| Utc::now().checked_add_signed(wait))
                    .unwrap_or(DateTime::<Utc>::MAX_UTC);
                self.held.insert(call, until);
            }
            // The API no longer takes the access token, whatever its expiry says, so the next call refreshes it.
            Err(AccountError::Refused { status: 401, .. }) => self.access = None,
            _ => {}
        }
        answer
    }
}

impl Account {
    // Reads the system's certificates, so it belongs off the GTK thread.
    pub fn new(
        settings: AccountSettings,
        vault: Arc<dyn RefreshTokenVault>,
        browser: Arc<dyn BrowserLauncher>,
        status: watch::Sender<AccountStatus>,
    ) -> Result<Self, AccountError> {
        // Redirects stay off so a token never follows one to another host.
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(format!(
                "TablePro/{} ({})",
                settings.device.app_version, settings.client.system
            ))
            .connect_timeout(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|error| AccountError::Protocol(error.to_string()))?;
        let oauth = OAuth::new(settings.client, &settings.endpoints, http.clone())?;
        Ok(Self {
            inner: Arc::new(Inner {
                settings,
                http,
                oauth,
                vault,
                browser,
                session: Mutex::new(Session::default()),
                status,
                due: watch::Sender::new(Instant::now()),
                attempts: AtomicU64::new(0),
            }),
        })
    }

    pub fn status(&self) -> watch::Receiver<AccountStatus> {
        self.inner.status.subscribe()
    }

    pub fn machine_id(&self) -> &MachineId {
        &self.inner.settings.machine_id
    }

    pub async fn run(&self) {
        self.restore().await;
        let mut due = self.inner.due.subscribe();
        loop {
            let refreshed = self.refresh_entitlement().await;
            if let Err(error) = &refreshed
                && next_refresh(&refreshed) == RETRY_INTERVAL
            {
                tracing::warn!(%error, "the entitlement refresh failed");
            }
            wait_until_due(&mut due, Utc::now).await;
        }
    }

    // Without account.json no one is signed in, so the keyring stays shut: opening it can prompt.
    pub async fn restore(&self) {
        let mut session = self.inner.session.lock().await;
        let path = &self.inner.settings.account_file;
        let file = match account_file::read(path).await {
            Ok(Some(file)) => file,
            Ok(None) => {
                self.signed_out(&mut session);
                return;
            }
            Err(error) => {
                tracing::warn!(%error, "the account file was not read");
                AccountFile::default()
            }
        };
        if file.offline_only {
            self.restore_offline(&mut session, file).await;
            return;
        }
        let refresh = match self.inner.vault.load_refresh_token().await {
            Ok(Some(refresh)) => refresh,
            Ok(None) => {
                if let Err(error) = account_file::remove(path).await {
                    tracing::warn!(%error, "the account file was not removed");
                }
                self.signed_out(&mut session);
                return;
            }
            Err(error) => {
                tracing::warn!(%error, "the keyring gave no account sign-in, so this run starts signed out");
                self.signed_out(&mut session);
                return;
            }
        };
        let kept = file.entitlement.as_deref().map(|token| (token, self.verify(token)));
        let (entitlement, problem) = match kept {
            None => (None, None),
            Some((_, Ok(entitlement))) => (Some(entitlement), None),
            Some((token, Err(EntitlementError::Expired(at)))) => {
                (self.lapsed(token, at), Some(EntitlementProblem::Expired))
            }
            Some((_, Err(error))) => {
                tracing::warn!(%error, "the kept entitlement does not verify");
                (None, None)
            }
        };
        *session = Session {
            refresh: Some(refresh),
            access: None,
            device_id: file.device_id,
            account_id: entitlement
                .as_ref()
                .map(|it| it.claims().sub.clone())
                .or(file.account_id),
            remembered: true,
            held: HashMap::new(),
        };
        self.publish(&session, entitlement, problem);
    }

    // No sign-in goes with it, so the keyring stays shut.
    async fn restore_offline(&self, session: &mut Session, file: AccountFile) {
        match file.entitlement.as_deref().map(|token| self.verify(token)) {
            Some(Ok(entitlement)) => {
                *session = Session::default();
                self.inner
                    .status
                    .send_replace(AccountStatus::Offline(Box::new(entitlement)));
            }
            kept => {
                if let Some(Err(error)) = kept {
                    tracing::info!(%error, "the imported offline file no longer verifies");
                }
                if let Err(error) = account_file::remove(&self.inner.settings.account_file).await {
                    tracing::warn!(%error, "the account file was not removed");
                }
                self.signed_out(session);
            }
        }
    }

    // An error after the code exchange leaves the account signed in, with the problem in its status. `cancelled`
    // ends only the wait for the browser: once the code is back, the tokens it brings are stored whatever happens.
    pub async fn sign_in(&self, cancelled: impl Future<Output = ()> + Send) -> Result<(), AccountError> {
        let attempt = self.inner.attempts.fetch_add(1, Ordering::SeqCst) + 1;
        let loopback = Loopback::bind()
            .await
            .map_err(|error| AccountError::Protocol(format!("no loopback port: {error}")))?;
        let authorization = self
            .inner
            .oauth
            .authorization(loopback.redirect_uri(), &self.inner.settings.device)?;
        self.inner
            .browser
            .open(&authorization.url)
            .await
            .map_err(AccountError::Browser)?;
        let waiting = loopback.wait(authorization.state.secret(), &self.inner.settings.callback_page);
        let callback = tokio::select! {
            waited = tokio::time::timeout(SIGN_IN_TIMEOUT, waiting) => waited,
            () = cancelled => return Err(AccountError::SignInCanceled),
        };
        let callback = callback
            .map_err(|_| AccountError::SignInTimedOut)?
            .map_err(|error| AccountError::Protocol(format!("the loopback listener failed: {error}")))?;
        let code = match callback {
            Callback::Code(code) => code,
            Callback::Refused { error, description } => {
                return Err(AccountError::SignInRefused { error, description });
            }
        };
        let tokens = self.inner.oauth.exchange_code(code, authorization).await?;
        self.commit_sign_in(attempt, tokens).await
    }

    // Only the latest sign-in or sign-out counts: tokens that come back for an attempt a later one superseded are
    // revoked, never adopted. Nothing replaces a working sign-in until the new one has a refresh token.
    async fn commit_sign_in(&self, attempt: u64, tokens: Tokens) -> Result<(), AccountError> {
        let Some(refresh) = tokens.refresh.clone().filter(|token| !token.expose_secret().is_empty()) else {
            return Err(AccountError::Protocol("the sign-in gave no refresh token".to_owned()));
        };
        let mut session = self.inner.session.lock().await;
        if self.inner.attempts.load(Ordering::SeqCst) != attempt {
            if let Err(error) = self.inner.oauth.revoke(&refresh).await {
                tracing::warn!(%error, "a superseded sign-in was not revoked");
            }
            return Err(AccountError::SignInCanceled);
        }
        // A sign-in over another, such as to switch accounts, ends the first one's token family.
        if let Some(previous) = session.refresh.take()
            && let Err(error) = self.inner.oauth.revoke(&previous).await
        {
            tracing::warn!(%error, "the previous sign-in was not revoked");
        }
        *session = Session::default();
        self.adopt(&mut session, tokens).await;
        self.write_file(&session, None).await;
        self.publish(&session, None, None);
        tracing::info!(remembered = session.remembered, "signed in to the TablePro account");
        let fetched = self.fetch_entitlement(&mut session).await;
        self.settle(&mut session, fetched).await
    }

    // Signs out locally even when the revocation fails, which the error then says.
    pub async fn sign_out(&self) -> Result<(), AccountError> {
        let mut session = self.inner.session.lock().await;
        self.inner.attempts.fetch_add(1, Ordering::SeqCst);
        let revoked = match session.refresh.as_ref() {
            Some(refresh) => self.inner.oauth.revoke(refresh).await,
            None => Ok(()),
        };
        self.forget(&mut session).await;
        tracing::info!("signed out of the TablePro account");
        revoked
    }

    pub async fn profile(&self) -> Result<Profile, AccountError> {
        let mut session = self.inner.session.lock().await;
        let fetched = self.fetch_profile(&mut session).await;
        self.ended_by(&mut session, fetched).await
    }

    pub async fn devices(&self) -> Result<Vec<Device>, AccountError> {
        let mut session = self.inner.session.lock().await;
        let fetched = self.fetch_devices(&mut session).await;
        self.ended_by(&mut session, fetched).await
    }

    // Over the device limit, the refresh gives the freed slot to this device, and its error is the caller's.
    pub async fn remove_device(&self, device_id: &str) -> Result<(), AccountError> {
        {
            let mut session = self.inner.session.lock().await;
            let removed = self.delete_device(&mut session, device_id).await;
            self.ended_by(&mut session, removed).await?;
        }
        tracing::info!("removed a device from the account");
        let past_limit = self.inner.status.borrow().past_device_limit();
        let refreshed = self.refresh_entitlement().await;
        match (past_limit, refreshed) {
            (true, refreshed) => refreshed,
            (false, Err(error)) => {
                tracing::warn!(%error, "the entitlement refresh after a device removal failed");
                Ok(())
            }
            (false, Ok(())) => Ok(()),
        }
    }

    // The file holds the token itself and passes the checks an online one does.
    pub async fn import_offline_file(&self, token: &str) -> Result<(), AccountError> {
        let token = token.trim();
        let entitlement = self.verify(token)?;
        let mut session = self.inner.session.lock().await;
        let signed_in = session.refresh.is_some();
        // Another account's file would show its plan, and identify its user, under this sign-in.
        if signed_in && self.account_id(&mut session).await? != entitlement.claims().sub {
            return Err(AccountError::OtherAccount);
        }
        let file = AccountFile {
            device_id: session.device_id.clone(),
            account_id: Some(entitlement.claims().sub.clone()),
            entitlement: Some(token.to_owned()),
            offline_only: !signed_in,
        };
        account_file::write(&self.inner.settings.account_file, &file).await?;
        tracing::info!(expires_at = %entitlement.expires_at(), signed_in, "imported an offline file");
        match signed_in {
            true => self.publish(&session, Some(entitlement), None),
            false => {
                self.inner
                    .status
                    .send_replace(AccountStatus::Offline(Box::new(entitlement)));
            }
        }
        Ok(())
    }

    // Call it after any change to the account too.
    pub async fn refresh_entitlement(&self) -> Result<(), AccountError> {
        let mut session = self.inner.session.lock().await;
        if session.refresh.is_none() {
            let signed_out = Err(AccountError::SignedOut);
            self.reschedule(&signed_out);
            return signed_out;
        }
        let fetched = self.fetch_entitlement(&mut session).await;
        self.settle(&mut session, fetched).await
    }

    // Back from the portal or another device, where a slot may have been freed.
    pub async fn refresh_past_device_limit(&self) -> Option<Result<(), AccountError>> {
        let past_limit = self.inner.status.borrow().past_device_limit();
        match past_limit {
            true => Some(self.refresh_entitlement().await),
            false => None,
        }
    }

    async fn fetch_entitlement(&self, session: &mut Session) -> Result<(), AccountError> {
        session.waited(Call::Entitlement)?;
        let device_id = match session.device_id.clone() {
            Some(device_id) => device_id,
            None => self.register(session).await?,
        };
        let bearer = self.bearer(session, false).await?;
        let device = &self.inner.settings.device;
        let request = v2::types::EntitlementRequest {
            app_version: field(&device.app_version)?,
            os_version: field(&device.os_version)?,
        };
        let answer = match self.api(bearer).issue_entitlement(&device_id, &request).await {
            Ok(answer) => Ok(answer.into_inner()),
            Err(error) => Err(answer_error(error).await),
        };
        let answer = session.answered(Call::Entitlement, answer)?;
        let entitlement = self.verify(&answer.token)?;
        session.account_id = Some(entitlement.claims().sub.clone());
        self.write_file(session, Some(entitlement.token().to_owned())).await;
        tracing::info!(features = entitlement.claims().features.len(), expires_at = %entitlement.expires_at(), "entitlement refreshed");
        self.publish(session, Some(entitlement), None);
        Ok(())
    }

    // With no entitlement since the sign-in, such as over the device limit, /v2/me says which.
    async fn account_id(&self, session: &mut Session) -> Result<String, AccountError> {
        if let Some(account_id) = &session.account_id {
            return Ok(account_id.clone());
        }
        let fetched = self.fetch_profile(session).await;
        let account_id = self.ended_by(session, fetched).await?.id;
        session.account_id = Some(account_id.clone());
        Ok(account_id)
    }

    async fn fetch_profile(&self, session: &mut Session) -> Result<Profile, AccountError> {
        session.waited(Call::Profile)?;
        let bearer = self.bearer(session, false).await?;
        let answer = match self.api(bearer).get_me().await {
            Ok(answer) => Ok(answer.into_inner().into()),
            Err(error) => Err(answer_error(error).await),
        };
        session.answered(Call::Profile, answer)
    }

    async fn fetch_devices(&self, session: &mut Session) -> Result<Vec<Device>, AccountError> {
        session.waited(Call::Devices)?;
        let api = self.api(self.bearer(session, false).await?);
        let mut devices = Vec::new();
        let mut cursor = None;
        for _ in 0..DEVICE_PAGES {
            let page = match api.list_devices(cursor.as_deref(), Some(DEVICE_PAGE)).await {
                Ok(answer) => answer.into_inner(),
                Err(error) => return session.answered(Call::Devices, Err(answer_error(error).await)),
            };
            devices.extend(page.data.into_iter().map(Device::from));
            cursor = page.next_cursor;
            if cursor.is_none() {
                break;
            }
        }
        Ok(devices)
    }

    async fn delete_device(&self, session: &mut Session, device_id: &str) -> Result<(), AccountError> {
        session.waited(Call::RemoveDevice)?;
        let bearer = self.bearer(session, false).await?;
        let answer = match self.api(bearer).delete_device(device_id).await {
            Ok(_) => Ok(()),
            Err(error) => Err(answer_error(error).await),
        };
        session.answered(Call::RemoveDevice, answer)
    }

    // A refused sign-in or a removed device ends the session, whichever call learns it.
    async fn ended_by<T>(&self, session: &mut Session, result: Result<T, AccountError>) -> Result<T, AccountError> {
        if let Err(AccountError::SignedOut | AccountError::DeviceRevoked) = &result
            && session.refresh.is_some()
        {
            self.forget(session).await;
        }
        result
    }

    async fn register(&self, session: &mut Session) -> Result<String, AccountError> {
        session.waited(Call::Register)?;
        let bearer = self.bearer(session, false).await?;
        let settings = &self.inner.settings;
        let registration = v2::types::DeviceRegistration {
            app_version: field(&settings.device.app_version)?,
            machine_id: field(settings.machine_id.as_str())?,
            name: field(&settings.device.name)?,
            os_version: field(&settings.device.os_version)?,
            platform: settings.client.platform,
        };
        let device = match self.api(bearer).register_device(&registration).await {
            Ok(answer) => Ok(answer.into_inner()),
            Err(error) => Err(answer_error(error).await),
        };
        let device = session.answered(Call::Register, device)?;
        session.device_id = Some(device.id.clone());
        self.write_file(session, None).await;
        // Only a token refreshed after the registration names the device; a retry must not reuse the one before.
        session.access = None;
        self.bearer(session, true).await?;
        Ok(device.id)
    }

    async fn bearer(&self, session: &mut Session, renew: bool) -> Result<Bearer, AccountError> {
        if !renew
            && let Some((access, until)) = &session.access
            && *until > Utc::now() + ACCESS_TOKEN_MARGIN
        {
            return Ok(Bearer(access.clone()));
        }
        let refresh = session.refresh.clone().ok_or(AccountError::SignedOut)?;
        session.waited(Call::Token)?;
        let tokens = self.inner.oauth.refresh(&refresh).await;
        let tokens = session.answered(Call::Token, tokens)?;
        let access = tokens.access.clone();
        self.adopt(session, tokens).await;
        Ok(Bearer(access))
    }

    async fn adopt(&self, session: &mut Session, tokens: Tokens) {
        let lifetime = TimeDelta::from_std(tokens.lifetime).unwrap_or_default();
        session.access = Some((tokens.access, Utc::now() + lifetime));
        let Some(refresh) = tokens.refresh else {
            return;
        };
        session.remembered = match self.inner.vault.store_refresh_token(&refresh).await {
            Ok(()) => true,
            Err(error) => {
                tracing::warn!(%error, "no keyring took the account's sign-in; it lasts until the app quits");
                // A rotated token presented again revokes the whole family.
                let _ = self.inner.vault.delete_refresh_token().await;
                false
            }
        };
        session.refresh = Some(refresh);
    }

    async fn settle(&self, session: &mut Session, result: Result<(), AccountError>) -> Result<(), AccountError> {
        self.reschedule(&result);
        let Err(error) = result else {
            return Ok(());
        };
        let kept = self.inner.status.borrow().entitlement().cloned();
        match &error {
            AccountError::SignedOut | AccountError::DeviceRevoked => self.forget(session).await,
            AccountError::DeviceLimitReached { devices } => {
                let problem = EntitlementProblem::DeviceLimitReached(devices.clone());
                self.publish(session, kept, Some(problem));
            }
            other => {
                let problem = EntitlementProblem::RefreshFailed(other.clone());
                self.publish(session, kept, Some(problem));
            }
        }
        Err(error)
    }

    async fn forget(&self, session: &mut Session) {
        if let Err(error) = self.inner.vault.delete_refresh_token().await {
            tracing::warn!(%error, "the account's sign-in was not removed from the keyring");
        }
        if let Err(error) = account_file::remove(&self.inner.settings.account_file).await {
            tracing::warn!(%error, "the account file was not removed");
        }
        self.signed_out(session);
    }

    fn reschedule(&self, refreshed: &Result<(), AccountError>) {
        self.inner.due.send_replace(Instant::now() + next_refresh(refreshed));
    }

    fn signed_out(&self, session: &mut Session) {
        *session = Session::default();
        self.inner.status.send_replace(AccountStatus::SignedOut);
    }

    fn publish(&self, session: &Session, entitlement: Option<Entitlement>, problem: Option<EntitlementProblem>) {
        self.inner
            .status
            .send_replace(AccountStatus::SignedIn(Box::new(SignedIn {
                entitlement,
                problem,
                remembered: session.remembered,
            })));
    }

    async fn write_file(&self, session: &Session, entitlement: Option<String>) {
        let file = AccountFile {
            device_id: session.device_id.clone(),
            account_id: session.account_id.clone(),
            entitlement,
            offline_only: false,
        };
        if let Err(error) = account_file::write(&self.inner.settings.account_file, &file).await {
            tracing::warn!(%error, "the account file was not written");
        }
    }

    // Still checked, at the moment before it expired: what it names says who has paid, as a lapse while the app
    // runs keeps it too. Only its features stop.
    fn lapsed(&self, token: &str, expired_at: DateTime<Utc>) -> Option<Entitlement> {
        let settings = &self.inner.settings;
        let before = expired_at - TimeDelta::seconds(1);
        Entitlement::verify(token, &settings.keys, settings.machine_id.as_str(), before).ok()
    }

    fn verify(&self, token: &str) -> Result<Entitlement, EntitlementError> {
        let settings = &self.inner.settings;
        Entitlement::verify(token, &settings.keys, settings.machine_id.as_str(), Utc::now())
    }

    fn api(&self, bearer: Bearer) -> v2::Client {
        v2::Client::new_with_client(&self.inner.settings.endpoints.api, self.inner.http.clone(), bearer)
    }
}

// clients.md, Shared rules: a day after a refresh that worked, an hour after one that failed or hit the device limit,
// and never before a 429's Retry-After.
fn next_refresh(refreshed: &Result<(), AccountError>) -> Duration {
    match refreshed {
        Ok(()) | Err(AccountError::SignedOut | AccountError::DeviceRevoked) => REFRESH_INTERVAL,
        Err(AccountError::RateLimited {
            retry_after: Some(retry_after),
        }) => RETRY_INTERVAL.max(*retry_after),
        Err(_) => RETRY_INTERVAL,
    }
}

// The time can move while it waits, earlier or later. Instant stops while the machine sleeps and the wall clock does
// not, so the wait also looks at the wall clock now and then.
async fn wait_until_due(due: &mut watch::Receiver<Instant>, wall_clock: impl Fn() -> DateTime<Utc>) {
    let deadline = |at: Instant| {
        TimeDelta::from_std(at.saturating_duration_since(Instant::now()))
            .ok()
            .and_then(|left| wall_clock().checked_add_signed(left))
            .unwrap_or(DateTime::<Utc>::MAX_UTC)
    };
    let mut at = *due.borrow_and_update();
    let mut wall = deadline(at);
    loop {
        if wall_clock() >= wall {
            return;
        }
        tokio::select! {
            () = tokio::time::sleep_until(at) => return,
            () = tokio::time::sleep(WALL_CLOCK_CHECK) => {}
            Ok(()) = due.changed() => {
                at = *due.borrow_and_update();
                wall = deadline(at);
            }
        }
    }
}

fn field<T: TryFrom<String>>(text: &str) -> Result<T, AccountError> {
    let cleaned: String = text.chars().filter(|character| !character.is_control()).collect();
    let cleaned: String = cleaned.trim().chars().take(FIELD_CHARACTERS).collect();
    T::try_from(cleaned).map_err(|_| AccountError::Protocol(format!("{text:?} is not a device field the server takes")))
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use async_trait::async_trait;
    use chrono::TimeDelta;
    use secrecy::ExposeSecret as _;
    use tablepro_core::credentials::SecretError;
    use url::Url;

    use super::*;
    use crate::account_settings::{AppClient, CallbackPage, DeviceDescription, Endpoints};
    use crate::account_status::FeatureAccess;
    use crate::entitlement::test_tokens::{claims, keys, sign};

    const FEATURE: &str = "env_var_references";
    const ACCOUNT: &str = "acct_01k8d6wk00f8xsr79e7x052rkk";
    const OTHER_ACCOUNT: &str = "acct_01k8d6x3q0f8xsr79e7x052zzz";

    // Counts every time the account opens it.
    struct Keyring {
        token: Mutex<Option<SecretString>>,
        opened: AtomicUsize,
    }

    impl Keyring {
        fn holding(token: Option<&str>) -> Arc<Self> {
            Arc::new(Self {
                token: Mutex::new(token.map(SecretString::from)),
                opened: AtomicUsize::new(0),
            })
        }

        fn opened(&self) -> usize {
            self.opened.load(Ordering::SeqCst)
        }
    }

    #[async_trait]
    impl RefreshTokenVault for Keyring {
        async fn load_refresh_token(&self) -> Result<Option<SecretString>, SecretError> {
            self.opened.fetch_add(1, Ordering::SeqCst);
            Ok(self.token.lock().await.clone())
        }

        async fn store_refresh_token(&self, token: &SecretString) -> Result<(), SecretError> {
            self.opened.fetch_add(1, Ordering::SeqCst);
            *self.token.lock().await = Some(token.clone());
            Ok(())
        }

        async fn delete_refresh_token(&self) -> Result<(), SecretError> {
            self.opened.fetch_add(1, Ordering::SeqCst);
            *self.token.lock().await = None;
            Ok(())
        }
    }

    struct NoBrowser;

    #[async_trait]
    impl BrowserLauncher for NoBrowser {
        async fn open(&self, _: &Url) -> Result<(), String> {
            Err("a unit test opens no browser".to_owned())
        }
    }

    fn machine() -> MachineId {
        MachineId::derive("4c4f5e2a0b6d4f3c9e8a7b6c5d4e3f20\n").expect("a machine ID")
    }

    // Nothing listens on the port once the listener is dropped, so every request is refused.
    fn unreachable() -> Endpoints {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints")
    }

    // Stands in for tablepro-cloud: `answer` gives the status and body for a method and path.
    fn cloud(answer: impl Fn(&str, &str) -> (u16, String) + Send + 'static) -> Endpoints {
        cloud_with_headers(move |method, path| {
            let (status, body) = answer(method, path);
            (status, "", body)
        })
    }

    // As cloud, with header lines such as "retry-after: 30\r\n" in the answer.
    fn cloud_with_headers(answer: impl Fn(&str, &str) -> (u16, &'static str, String) + Send + 'static) -> Endpoints {
        cloud_with_bodies(move |method, path, _| answer(method, path))
    }

    // As cloud_with_headers, also given the request's body.
    fn cloud_with_bodies(
        answer: impl Fn(&str, &str, &str) -> (u16, &'static str, String) + Send + 'static,
    ) -> Endpoints {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("a free port");
        let base = format!("http://{}", listener.local_addr().expect("its address"));
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                serve(stream, &answer);
            }
        });
        Endpoints::new(&base, &format!("{base}/v2")).expect("the endpoints")
    }

    fn serve(stream: std::net::TcpStream, answer: &dyn Fn(&str, &str, &str) -> (u16, &'static str, String)) {
        use std::io::{BufRead as _, Read as _, Write as _};
        let mut reader = std::io::BufReader::new(stream.try_clone().expect("a second handle"));
        let mut line = String::new();
        reader.read_line(&mut line).expect("the request line");
        let mut words = line.split_whitespace();
        let (method, path) = (words.next().unwrap_or_default(), words.next().unwrap_or_default());
        let mut length = 0;
        loop {
            let mut header = String::new();
            reader.read_line(&mut header).expect("a header");
            if header.trim().is_empty() {
                break;
            }
            if let Some(value) = header.to_ascii_lowercase().strip_prefix("content-length:") {
                length = value.trim().parse().expect("a length");
            }
        }
        let mut request = vec![0; length];
        reader.read_exact(&mut request).expect("the body");
        let (status, headers, body) = answer(method, path, &String::from_utf8_lossy(&request));
        let mut stream = stream;
        write!(
            stream,
            "HTTP/1.1 {status} Stub\r\ncontent-type: application/json\r\n{headers}content-length: {}\r\nconnection: close\r\n\r\n{body}",
            body.len()
        )
        .expect("the answer");
    }

    const TOKENS: &str =
        r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900,"refresh_token":"stub-refresh"}"#;

    fn account(dir: &Path, keyring: Arc<Keyring>) -> Account {
        account_at(dir, keyring, unreachable())
    }

    fn account_at(dir: &Path, keyring: Arc<Keyring>, endpoints: Endpoints) -> Account {
        let settings = AccountSettings {
            client: AppClient::LINUX,
            endpoints,
            device: DeviceDescription {
                name: "Ada's laptop".to_owned(),
                app_version: "0.1.0".to_owned(),
                os_version: "Fedora Linux 43 (Workstation Edition)".to_owned(),
            },
            machine_id: machine(),
            keys: keys(),
            account_file: dir.join("account.json"),
            callback_page: CallbackPage {
                finished: String::new(),
                unknown: String::new(),
            },
        };
        let status = watch::Sender::new(AccountStatus::SignedOut);
        Account::new(settings, keyring, Arc::new(NoBrowser), status).expect("an account")
    }

    // As a refresh writes it: the account goes with the entitlement.
    async fn keep(dir: &Path, entitlement: Option<String>) {
        let file = AccountFile {
            device_id: Some("dev_01k8d6wpggfd68tbhz818p4ww4".to_owned()),
            account_id: entitlement.as_ref().map(|_| ACCOUNT.to_owned()),
            entitlement,
            offline_only: false,
        };
        account_file::write(&dir.join("account.json"), &file)
            .await
            .expect("the account file");
    }

    fn entitlement(issued: chrono::DateTime<Utc>) -> String {
        let mut claims = claims(issued, TimeDelta::days(14), &[FEATURE]);
        claims.mid = machine().as_str().to_owned();
        sign(&claims)
    }

    fn offline_file(issued: chrono::DateTime<Utc>) -> String {
        let mut claims = claims(issued, TimeDelta::days(30), &[FEATURE]);
        claims.mid = machine().as_str().to_owned();
        claims.offline = true;
        sign(&claims)
    }

    fn another_accounts_offline_file() -> String {
        let mut claims = claims(Utc::now(), TimeDelta::days(30), &["team_library"]);
        claims.mid = machine().as_str().to_owned();
        claims.offline = true;
        claims.sub = OTHER_ACCOUNT.to_owned();
        sign(&claims)
    }

    fn signed_in(account: &Account) -> SignedIn {
        match &*account.status().borrow() {
            AccountStatus::SignedIn(signed_in) => (**signed_in).clone(),
            other => panic!("the account is not signed in: {other:?}"),
        }
    }

    async fn stored(dir: &Path) -> AccountFile {
        account_file::read(&dir.join("account.json"))
            .await
            .expect("read")
            .expect("an account file")
    }

    #[tokio::test]
    async fn an_offline_file_unlocks_a_signed_out_machine_without_the_keyring() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let keyring = Keyring::holding(None);
        let account = account(dir.path(), keyring.clone());
        account.restore().await;

        account
            .import_offline_file(&format!("{}\n", offline_file(Utc::now())))
            .await
            .expect("imported");

        assert!(matches!(*account.status().borrow(), AccountStatus::Offline(_)));
        assert_eq!(
            account.status().borrow().feature_access(FEATURE, Utc::now()),
            FeatureAccess::Available
        );
        assert!(stored(dir.path()).await.offline_only);
        let restarted = self::account(dir.path(), keyring.clone());
        restarted.restore().await;
        assert!(matches!(*restarted.status().borrow(), AccountStatus::Offline(_)));
        assert_eq!(keyring.opened(), 0);
    }

    #[tokio::test]
    async fn a_file_for_another_machine_is_refused_and_nothing_is_kept() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let account = account(dir.path(), Keyring::holding(None));
        let mut claims = claims(Utc::now(), TimeDelta::days(30), &[FEATURE]);
        claims.offline = true;

        let imported = account.import_offline_file(&sign(&claims)).await;

        assert!(
            matches!(imported, Err(AccountError::Entitlement(EntitlementError::Machine))),
            "{imported:?}"
        );
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        assert!(!dir.path().join("account.json").exists());
    }

    #[tokio::test]
    async fn an_offline_file_that_expired_is_dropped_at_restore() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let path = dir.path().join("account.json");
        let file = AccountFile {
            device_id: None,
            account_id: None,
            entitlement: Some(offline_file(Utc::now() - TimeDelta::days(40))),
            offline_only: true,
        };
        account_file::write(&path, &file).await.expect("the account file");
        let keyring = Keyring::holding(None);
        let account = account(dir.path(), keyring.clone());

        account.restore().await;

        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        assert!(!path.exists());
        assert_eq!(keyring.opened(), 0);
    }

    #[tokio::test]
    async fn signed_in_an_offline_file_replaces_the_entitlement_and_keeps_the_sign_in() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), Some(entitlement(Utc::now()))).await;
        let account = account(dir.path(), Keyring::holding(Some("refresh")));
        account.restore().await;
        let token = offline_file(Utc::now());

        account.import_offline_file(&token).await.expect("imported");

        let held = signed_in(&account);
        assert_eq!(held.entitlement.map(|it| it.claims().offline), Some(true));
        let file = stored(dir.path()).await;
        assert!(!file.offline_only);
        assert_eq!(file.entitlement.as_deref(), Some(token.as_str()));
        assert_eq!(file.device_id.as_deref(), Some("dev_01k8d6wpggfd68tbhz818p4ww4"));
        assert_eq!(file.account_id.as_deref(), Some(ACCOUNT));
    }

    #[tokio::test]
    async fn signed_in_a_file_of_another_account_is_refused_and_one_of_this_account_is_taken() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let online = entitlement(Utc::now());
        keep(dir.path(), Some(online.clone())).await;
        let account = account(dir.path(), Keyring::holding(Some("refresh")));
        account.restore().await;

        let refused = account.import_offline_file(&another_accounts_offline_file()).await;

        assert!(matches!(refused, Err(AccountError::OtherAccount)), "{refused:?}");
        let held = signed_in(&account);
        assert_eq!(
            held.entitlement.map(|it| it.claims().sub.clone()).as_deref(),
            Some(ACCOUNT)
        );
        assert_eq!(stored(dir.path()).await.entitlement.as_deref(), Some(online.as_str()));
        account
            .import_offline_file(&offline_file(Utc::now()))
            .await
            .expect("this account's file");
        assert_eq!(
            signed_in(&account).entitlement.map(|it| it.claims().offline),
            Some(true)
        );
    }

    #[tokio::test]
    async fn signed_in_after_the_entitlement_expired_a_file_of_another_account_is_still_refused() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let file = AccountFile {
            device_id: Some("dev_01k8d6wpggfd68tbhz818p4ww4".to_owned()),
            account_id: Some(ACCOUNT.to_owned()),
            entitlement: Some(entitlement(Utc::now() - TimeDelta::days(20))),
            offline_only: false,
        };
        account_file::write(&dir.path().join("account.json"), &file)
            .await
            .expect("the account file");
        let account = account(dir.path(), Keyring::holding(Some("refresh")));
        account.restore().await;
        assert!(matches!(signed_in(&account).problem, Some(EntitlementProblem::Expired)));

        let refused = account.import_offline_file(&another_accounts_offline_file()).await;

        assert!(matches!(refused, Err(AccountError::OtherAccount)), "{refused:?}");
        let kept = signed_in(&account).entitlement.expect("the lapsed entitlement");
        assert_eq!(kept.claims().sub, ACCOUNT);
        assert!(!kept.is_current(Utc::now()));
        let token = offline_file(Utc::now());
        account.import_offline_file(&token).await.expect("this account's file");
        let kept = stored(dir.path()).await;
        assert_eq!(
            (kept.account_id.as_deref(), kept.entitlement.as_deref()),
            (Some(ACCOUNT), Some(token.as_str()))
        );
    }

    #[tokio::test]
    async fn over_the_device_limit_at_sign_in_the_account_service_names_the_account() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let problem = r#"{"type":"about:blank","title":"Device limit reached","status":409,"code":"device_limit_reached","devices":[]}"#;
        let me = format!(r#"{{"account":{{"id":"{ACCOUNT}","email":"ada@m17.example"}},"licenses":[],"teams":[]}}"#);
        let endpoints = cloud(move |method, path| match (method, path) {
            ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
            ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (409, problem.to_owned()),
            ("GET", "/v2/me") => (200, me.clone()),
            _ => (404, String::new()),
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let limited = account.refresh_entitlement().await;
        let refused = account.import_offline_file(&another_accounts_offline_file()).await;

        assert!(
            matches!(limited, Err(AccountError::DeviceLimitReached { .. })),
            "{limited:?}"
        );
        assert!(matches!(refused, Err(AccountError::OtherAccount)), "{refused:?}");
        assert!(signed_in(&account).entitlement.is_none());
        account
            .import_offline_file(&offline_file(Utc::now()))
            .await
            .expect("this account's file");
        assert_eq!(
            signed_in(&account).entitlement.map(|it| it.claims().offline),
            Some(true)
        );
    }

    #[tokio::test]
    async fn a_refreshed_entitlement_keeps_its_account_in_the_file() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let answer = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            entitlement(Utc::now())
        );
        let endpoints = cloud(move |method, path| match (method, path) {
            ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
            ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (200, answer.clone()),
            _ => (404, String::new()),
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        account.refresh_entitlement().await.expect("refreshed");

        assert_eq!(stored(dir.path()).await.account_id.as_deref(), Some(ACCOUNT));
    }

    #[tokio::test]
    async fn signed_out_the_account_service_is_not_asked() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let account = account(dir.path(), Keyring::holding(None));
        account
            .import_offline_file(&offline_file(Utc::now()))
            .await
            .expect("imported");

        let profile = account.profile().await;
        let devices = account.devices().await;
        let removed = account.remove_device("dev_01k8d6wpggfd68tbhz818p4ww4").await;

        assert!(matches!(profile, Err(AccountError::SignedOut)), "{profile:?}");
        assert!(matches!(devices, Err(AccountError::SignedOut)), "{devices:?}");
        assert!(matches!(removed, Err(AccountError::SignedOut)), "{removed:?}");
        assert!(matches!(*account.status().borrow(), AccountStatus::Offline(_)));
        assert!(dir.path().join("account.json").exists());
    }

    #[tokio::test(start_paused = true)]
    async fn without_an_account_file_the_keyring_is_never_opened() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let keyring = Keyring::holding(Some("left by an earlier install"));
        let account = account(dir.path(), keyring.clone());

        let running = tokio::spawn({
            let account = account.clone();
            async move { account.run().await }
        });
        tokio::time::sleep(REFRESH_INTERVAL * 2 + RETRY_INTERVAL).await;
        running.abort();

        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        assert_eq!(keyring.opened(), 0);
    }

    #[tokio::test]
    async fn an_account_file_without_a_keyring_token_is_removed() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let keyring = Keyring::holding(None);
        let account = account(dir.path(), keyring.clone());

        account.restore().await;

        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
        assert!(!dir.path().join("account.json").exists());
        assert_eq!(keyring.opened(), 1);
    }

    #[tokio::test]
    async fn a_kept_entitlement_unlocks_its_features_at_restore() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), Some(entitlement(Utc::now()))).await;
        let account = account(dir.path(), Keyring::holding(Some("refresh")));

        account.restore().await;

        let status = account.status().borrow().clone();
        assert!(signed_in(&account).problem.is_none());
        assert_eq!(status.feature_access(FEATURE, Utc::now()), FeatureAccess::Available);
    }

    #[tokio::test]
    async fn a_kept_entitlement_that_expired_restores_as_expired() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), Some(entitlement(Utc::now() - TimeDelta::days(20)))).await;
        let account = account(dir.path(), Keyring::holding(Some("refresh")));

        account.restore().await;

        let held = signed_in(&account);
        assert!(held.entitlement.is_some_and(|lapsed| !lapsed.is_current(Utc::now())));
        assert!(
            matches!(held.problem, Some(EntitlementProblem::Expired)),
            "{:?}",
            held.problem
        );
        assert_eq!(
            account.status().borrow().feature_access(FEATURE, Utc::now()),
            FeatureAccess::Expired
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_failed_refresh_is_tried_again_an_hour_later() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let account = account(dir.path(), Keyring::holding(Some("refresh")));
        let mut status = account.status();

        let started = Instant::now();
        let running = tokio::spawn({
            let account = account.clone();
            async move { account.run().await }
        });
        let mut failures = Vec::new();
        while failures.len() < 3 {
            status.changed().await.expect("the account runs");
            if let AccountStatus::SignedIn(held) = &*status.borrow_and_update()
                && let Some(EntitlementProblem::RefreshFailed(error)) = &held.problem
            {
                assert!(matches!(error, AccountError::Unreachable(_)), "{error:?}");
                failures.push(started.elapsed());
            }
        }
        running.abort();

        // A request may run into its own timeouts first under the paused clock.
        let slack = REQUEST_TIMEOUT + CONNECT_TIMEOUT;
        assert!(failures[0] <= slack, "{failures:?}");
        for pair in failures.windows(2) {
            let gap = pair[1] - pair[0];
            assert!(gap >= RETRY_INTERVAL && gap <= RETRY_INTERVAL + slack, "{failures:?}");
        }
    }

    #[test]
    fn a_day_follows_a_refresh_that_worked_or_signed_out_and_an_hour_any_other() {
        let daily = [Ok(()), Err(AccountError::SignedOut), Err(AccountError::DeviceRevoked)];
        let hourly = [
            AccountError::Unreachable("connection refused".to_owned()),
            AccountError::Refused {
                status: 503,
                code: "unavailable".to_owned(),
                detail: String::new(),
            },
            AccountError::DeviceLimitReached { devices: Vec::new() },
            AccountError::Entitlement(EntitlementError::Signature),
        ];

        for refreshed in &daily {
            assert_eq!(next_refresh(refreshed), REFRESH_INTERVAL, "{refreshed:?}");
        }
        for error in hourly {
            assert_eq!(next_refresh(&Err(error)), RETRY_INTERVAL);
        }
    }

    type Asked = Arc<std::sync::Mutex<Vec<String>>>;

    // Answers the entitlement with the device limit until `freed`, and keeps what it was asked.
    fn limit_cloud(freed: Arc<AtomicBool>, asked: Asked) -> Endpoints {
        let limited = r#"{"type":"about:blank","title":"Device limit reached","status":409,"code":"device_limit_reached","devices":[]}"#;
        let answer = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            entitlement(Utc::now())
        );
        cloud(move |method, path| {
            asked.lock().expect("the requests").push(format!("{method} {path}"));
            match (method, path) {
                ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") if freed.load(Ordering::SeqCst) => {
                    (200, answer.clone())
                }
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (409, limited.to_owned()),
                ("DELETE", "/v2/devices/dev_other") => (204, String::new()),
                _ => (404, String::new()),
            }
        })
    }

    fn asked(asked: &Asked) -> Vec<String> {
        asked.lock().expect("the requests").clone()
    }

    fn due_in(account: &Account) -> Duration {
        account.inner.due.borrow().saturating_duration_since(Instant::now())
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn the_next_refresh_follows_the_last_one_whoever_asked_for_it() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let freed = Arc::new(AtomicBool::new(false));
        let endpoints = limit_cloud(freed.clone(), Asked::default());
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;
        let minute = Duration::from_secs(60);

        let limited = account.refresh_entitlement().await;
        let after_limit = due_in(&account);
        freed.store(true, Ordering::SeqCst);
        account.refresh_entitlement().await.expect("refreshed");
        let after_success = due_in(&account);

        assert!(
            matches!(limited, Err(AccountError::DeviceLimitReached { .. })),
            "{limited:?}"
        );
        assert!(
            after_limit > RETRY_INTERVAL - minute && after_limit <= RETRY_INTERVAL,
            "{after_limit:?}"
        );
        assert!(
            after_success > REFRESH_INTERVAL - minute && after_success <= REFRESH_INTERVAL,
            "{after_success:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_removed_device_refreshes_the_entitlement_within_the_limit_too() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), Some(entitlement(Utc::now()))).await;
        let requests = Asked::default();
        let endpoints = limit_cloud(Arc::new(AtomicBool::new(true)), requests.clone());
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        account.remove_device("dev_other").await.expect("removed");

        let asked = asked(&requests);
        let removed = asked
            .iter()
            .position(|request| request == "DELETE /v2/devices/dev_other");
        let refreshed = asked.iter().rposition(|request| request.ends_with("/entitlement"));
        assert!(
            matches!((removed, refreshed), (Some(removed), Some(refreshed)) if refreshed > removed),
            "{asked:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn becoming_active_refreshes_only_past_the_device_limit() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let requests = Asked::default();
        let freed = Arc::new(AtomicBool::new(false));
        let endpoints = limit_cloud(freed.clone(), requests.clone());
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let before = account.refresh_past_device_limit().await;
        let limited = account.refresh_entitlement().await;
        freed.store(true, Ordering::SeqCst);
        let past = account.refresh_past_device_limit().await;
        let within = account.refresh_past_device_limit().await;

        assert!(before.is_none(), "{before:?}");
        assert!(
            matches!(limited, Err(AccountError::DeviceLimitReached { .. })),
            "{limited:?}"
        );
        assert!(matches!(past, Some(Ok(()))), "{past:?}");
        assert!(within.is_none(), "{within:?}");
        let refreshes = asked(&requests)
            .iter()
            .filter(|request| request.ends_with("/entitlement"))
            .count();
        assert_eq!(refreshes, 2);
    }

    #[test]
    fn a_retry_after_longer_than_the_hour_moves_the_next_refresh_past_it() {
        let limited = |seconds: Option<u64>| {
            next_refresh(&Err(AccountError::RateLimited {
                retry_after: seconds.map(Duration::from_secs),
            }))
        };

        assert_eq!(limited(Some(2 * 60 * 60)), Duration::from_secs(2 * 60 * 60));
        assert_eq!(limited(Some(30)), RETRY_INTERVAL);
        assert_eq!(limited(None), RETRY_INTERVAL);
    }

    const LIMITED: &str = r#"{"type":"about:blank","title":"Too many requests","status":429,"code":"rate_limited"}"#;

    fn sent(asked: &Asked, ending: &str) -> usize {
        self::asked(asked)
            .iter()
            .filter(|request| request.ends_with(ending))
            .count()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_429_holds_the_call_back_until_its_retry_after_passes() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let requests = Asked::default();
        let answer = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            entitlement(Utc::now())
        );
        let first = Arc::new(AtomicBool::new(true));
        let asked = requests.clone();
        let endpoints = cloud_with_headers(move |method, path| {
            asked.lock().expect("the requests").push(format!("{method} {path}"));
            match (method, path) {
                ("POST", "/oauth/token") => (200, "", TOKENS.to_owned()),
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement")
                    if first.swap(false, Ordering::SeqCst) =>
                {
                    (429, "retry-after: 1\r\n", LIMITED.to_owned())
                }
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (200, "", answer.clone()),
                _ => (404, "", String::new()),
            }
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let limited = account.refresh_entitlement().await;
        let held = account.refresh_entitlement().await;
        let sent_while_held = sent(&requests, "/entitlement");
        tokio::time::sleep(Duration::from_millis(1100)).await;
        let after = account.refresh_entitlement().await;

        assert!(
            matches!(limited, Err(AccountError::RateLimited { retry_after: Some(wait) }) if wait == Duration::from_secs(1)),
            "{limited:?}"
        );
        assert!(
            matches!(held, Err(AccountError::RateLimited { retry_after: Some(wait) }) if wait <= Duration::from_secs(1)),
            "{held:?}"
        );
        assert_eq!(sent_while_held, 1);
        assert!(after.is_ok(), "{after:?}");
        assert_eq!(sent(&requests, "/entitlement"), 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_429_from_the_token_endpoint_holds_the_token_refresh_back() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let requests = Asked::default();
        let asked = requests.clone();
        let endpoints = cloud_with_headers(move |method, path| {
            asked.lock().expect("the requests").push(format!("{method} {path}"));
            match (method, path) {
                ("POST", "/oauth/token") => (
                    429,
                    "retry-after: 30\r\n",
                    r#"{"error":"temporarily_unavailable"}"#.to_owned(),
                ),
                _ => (404, "", String::new()),
            }
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let limited = account.refresh_entitlement().await;
        let held = account.profile().await;

        assert!(
            matches!(limited, Err(AccountError::RateLimited { retry_after: Some(wait) }) if wait == Duration::from_secs(30)),
            "{limited:?}"
        );
        assert!(
            matches!(held, Err(AccountError::RateLimited { retry_after: Some(wait) }) if wait <= Duration::from_secs(30)),
            "{held:?}"
        );
        assert_eq!(sent(&requests, "/oauth/token"), 1);
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedIn(_)));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_access_token_the_api_refused_is_refreshed_before_the_next_call() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), None).await;
        let requests = Asked::default();
        let answer = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            entitlement(Utc::now())
        );
        let first = Arc::new(AtomicBool::new(true));
        let log = requests.clone();
        let endpoints = cloud(move |method, path| {
            log.lock().expect("the requests").push(format!("{method} {path}"));
            match (method, path) {
                ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement")
                    if first.swap(false, Ordering::SeqCst) =>
                {
                    (
                        401,
                        r#"{"type":"about:blank","title":"Unauthorized","status":401,"code":"unauthorized"}"#
                            .to_owned(),
                    )
                }
                ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (200, answer.clone()),
                _ => (404, String::new()),
            }
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let refused = account.refresh_entitlement().await;
        let tried_again = account.refresh_entitlement().await;

        assert!(
            matches!(refused, Err(AccountError::Refused { status: 401, .. })),
            "{refused:?}"
        );
        assert!(tried_again.is_ok(), "{tried_again:?}");
        assert_eq!(
            asked(&requests),
            [
                "POST /oauth/token",
                "POST /v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement",
                "POST /oauth/token",
                "POST /v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement",
            ]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_refresh_that_came_due_during_a_sleep_runs_soon_after_the_wake() {
        let due = watch::Sender::new(Instant::now() + REFRESH_INTERVAL);
        let mut receiver = due.subscribe();
        let asleep = Arc::new(std::sync::Mutex::new(TimeDelta::zero()));
        let wall_clock = {
            let asleep = asleep.clone();
            move || Utc::now() + *asleep.lock().expect("the sleep")
        };
        let started = Instant::now();
        let waiting = tokio::spawn(async move {
            wait_until_due(&mut receiver, wall_clock).await;
            Instant::now()
        });
        tokio::time::sleep(Duration::from_secs(60)).await;

        // Instant stood still for the night; only the wall clock moved.
        *asleep.lock().expect("the sleep") = TimeDelta::days(1);
        let woke = waiting.await.expect("woke");

        assert!(woke - started <= Duration::from_secs(60) + WALL_CLOCK_CHECK);
        drop(due);
    }

    #[tokio::test(start_paused = true)]
    async fn the_schedule_wakes_at_the_time_it_was_last_moved_to() {
        let due = watch::Sender::new(Instant::now() + RETRY_INTERVAL);
        let mut receiver = due.subscribe();
        let started = Instant::now();
        let waiting = tokio::spawn(async move {
            wait_until_due(&mut receiver, Utc::now).await;
            Instant::now()
        });
        tokio::time::sleep(RETRY_INTERVAL / 2).await;

        due.send_replace(Instant::now() + REFRESH_INTERVAL);
        tokio::time::sleep(RETRY_INTERVAL).await;
        assert!(!waiting.is_finished());
        due.send_replace(Instant::now() + RETRY_INTERVAL);
        let woke = waiting.await.expect("woke");

        assert_eq!(
            (woke - started).as_secs(),
            (RETRY_INTERVAL / 2 + RETRY_INTERVAL * 2).as_secs()
        );
    }

    #[test]
    fn a_device_field_is_cleaned_and_cut_to_100_characters() {
        let long: v2::types::DeviceRegistrationName =
            field(&format!(" Ada's\u{7}laptop {}", "é".repeat(200))).expect("a name");
        let empty = field::<v2::types::DeviceRegistrationName>(" \n\t");

        assert!(long.starts_with("Ada'slaptop "));
        assert_eq!(long.chars().count(), 100);
        assert!(empty.is_err());
    }

    fn device_answer() -> String {
        format!(
            r#"{{"id":"dev_01k8d6wpggfd68tbhz818p4ww4","machine_id":"{}","platform":"linux","name":"Ada's laptop","app_version":"0.1.0","os_version":"Fedora Linux 43 (Workstation Edition)","created_at":"2026-10-29T00:00:00Z","last_seen_at":"2026-10-29T00:00:00Z"}}"#,
            machine().as_str()
        )
    }

    fn form(body: &str) -> HashMap<String, String> {
        url::form_urlencoded::parse(body.as_bytes()).into_owned().collect()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_refresh_that_failed_after_the_registration_is_not_answered_with_the_unbound_token() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let file = AccountFile {
            device_id: None,
            account_id: Some(ACCOUNT.to_owned()),
            entitlement: None,
            offline_only: false,
        };
        account_file::write(&dir.path().join("account.json"), &file)
            .await
            .expect("the account file");
        let requests = Asked::default();
        let tokens_asked = Arc::new(AtomicUsize::new(0));
        let answer = format!(
            r#"{{"token":"{}","expires_at":"2026-11-12T00:00:00Z","refresh_after":"2026-10-30T00:00:00Z"}}"#,
            entitlement(Utc::now())
        );
        let device = device_answer();
        let endpoints = cloud({
            let requests = requests.clone();
            let tokens_asked = tokens_asked.clone();
            move |method, path| {
                requests.lock().expect("the requests").push(format!("{method} {path}"));
                match (method, path) {
                    ("POST", "/oauth/token") if tokens_asked.fetch_add(1, Ordering::SeqCst) == 1 => {
                        (503, "upstream unavailable".to_owned())
                    }
                    ("POST", "/oauth/token") => (200, TOKENS.to_owned()),
                    ("POST", "/v2/devices") => (201, device.clone()),
                    ("POST", "/v2/devices/dev_01k8d6wpggfd68tbhz818p4ww4/entitlement") => (200, answer.clone()),
                    _ => (404, String::new()),
                }
            }
        });
        let account = account_at(dir.path(), Keyring::holding(Some("refresh")), endpoints);
        account.restore().await;

        let failed = account.refresh_entitlement().await;
        account.refresh_entitlement().await.expect("refreshed");

        assert!(failed.is_err());
        let asked = asked(&requests);
        let tokens = asked.iter().filter(|request| *request == "POST /oauth/token").count();
        let last_token = asked.iter().rposition(|request| request == "POST /oauth/token");
        let entitlement = asked.iter().position(|request| request.ends_with("/entitlement"));
        assert_eq!(tokens, 3, "{asked:?}");
        assert!(
            matches!((last_token, entitlement), (Some(token), Some(asked_for)) if token < asked_for),
            "{asked:?}"
        );
    }

    // Keeps the authorization URL for the test to answer when it chooses.
    #[derive(Default)]
    struct HeldBrowser {
        opened: std::sync::Mutex<Option<Url>>,
    }

    #[async_trait]
    impl BrowserLauncher for HeldBrowser {
        async fn open(&self, url: &Url) -> Result<(), String> {
            *self.opened.lock().expect("the URL") = Some(url.clone());
            Ok(())
        }
    }

    fn held_account(dir: &Path, keyring: Arc<Keyring>, endpoints: Endpoints, browser: Arc<HeldBrowser>) -> Account {
        let settings = AccountSettings {
            client: AppClient::LINUX,
            endpoints,
            device: DeviceDescription {
                name: "Ada's laptop".to_owned(),
                app_version: "0.1.0".to_owned(),
                os_version: "Fedora Linux 43 (Workstation Edition)".to_owned(),
            },
            machine_id: machine(),
            keys: keys(),
            account_file: dir.join("account.json"),
            callback_page: CallbackPage {
                finished: String::new(),
                unknown: String::new(),
            },
        };
        Account::new(settings, keyring, browser, watch::Sender::new(AccountStatus::SignedOut)).expect("an account")
    }

    // Answers the redirect the sign-in waits for, as the browser would once the user approves.
    async fn approve(browser: &HeldBrowser) {
        let url = loop {
            if let Some(url) = browser.opened.lock().expect("the URL").clone() {
                break url;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        let asked = |name: &str| {
            url.query_pairs()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.into_owned())
        };
        let mut redirect = Url::parse(&asked("redirect_uri").expect("a redirect")).expect("a URL");
        redirect
            .query_pairs_mut()
            .append_pair("code", "late-code")
            .append_pair("state", &asked("state").expect("a state"));
        reqwest::get(redirect).await.expect("the redirect delivered");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_browser_sign_in_that_comes_back_after_a_sign_out_is_revoked_not_adopted() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        let revoked = Arc::new(std::sync::Mutex::new(Vec::new()));
        let endpoints = cloud_with_bodies({
            let revoked = revoked.clone();
            move |method, path, body| match (method, path) {
                ("POST", "/oauth/token") => (200, "", TOKENS.to_owned()),
                ("POST", "/oauth/revoke") => {
                    revoked
                        .lock()
                        .expect("the revocations")
                        .push(form(body).get("token").cloned().unwrap_or_default());
                    (200, "", String::new())
                }
                _ => (404, "", String::new()),
            }
        });
        let keyring = Keyring::holding(None);
        let browser = Arc::new(HeldBrowser::default());
        let account = held_account(dir.path(), keyring.clone(), endpoints, browser.clone());
        let signing_in = tokio::spawn({
            let account = account.clone();
            async move { account.sign_in(std::future::pending()).await }
        });
        while browser.opened.lock().expect("the URL").is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }

        account.sign_out().await.expect("signed out");
        approve(&browser).await;
        let late = signing_in.await.expect("the sign-in task");

        assert!(matches!(late, Err(AccountError::SignInCanceled)), "{late:?}");
        assert_eq!(*revoked.lock().expect("the revocations"), ["stub-refresh"]);
        assert!(keyring.token.lock().await.is_none());
        assert!(matches!(*account.status().borrow(), AccountStatus::SignedOut));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_sign_in_that_brings_no_refresh_token_leaves_the_earlier_one_as_it_was() {
        let dir = tempfile::tempdir().expect("a temporary directory");
        keep(dir.path(), Some(entitlement(Utc::now()))).await;
        let endpoints = cloud(|method, path| match (method, path) {
            ("POST", "/oauth/token") => (
                200,
                r#"{"access_token":"stub-access","token_type":"Bearer","expires_in":900}"#.to_owned(),
            ),
            _ => (404, String::new()),
        });
        let keyring = Keyring::holding(Some("earlier-refresh"));
        let browser = Arc::new(HeldBrowser::default());
        let account = held_account(dir.path(), keyring.clone(), endpoints, browser.clone());
        account.restore().await;
        let signing_in = tokio::spawn({
            let account = account.clone();
            async move { account.sign_in(std::future::pending()).await }
        });

        approve(&browser).await;
        let refused = signing_in.await.expect("the sign-in task");

        assert!(matches!(refused, Err(AccountError::Protocol(_))), "{refused:?}");
        assert_eq!(
            keyring
                .token
                .lock()
                .await
                .as_ref()
                .map(|token| token.expose_secret().to_owned())
                .as_deref(),
            Some("earlier-refresh")
        );
        assert!(signed_in(&account).entitlement.is_some());
    }
}
