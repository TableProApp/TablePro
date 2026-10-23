use std::sync::Arc;

use gtk4::prelude::*;
use tablepro_core::keyspace::{KeyScan, database_number};
use tablepro_session::runtime::Tasks;
use tablepro_session::{OperationError, OperationKind, Session};
use tokio_util::sync::CancellationToken;

use super::sidebar_index::SidebarIndex;
use crate::runtime::DeliverInput;
use crate::ui::workspace::{WorkspaceInput, WorkspaceModel};

/// What a key-value engine's sidebar keeps beside its list.
pub(crate) struct KeySidebar {
    /// Says the sidebar lists only some of the keys.
    limit_banner: libadwaita::Banner,
    /// Stops the listing running, when a newer one replaces it.
    listing: Option<CancellationToken>,
}

impl KeySidebar {
    pub(crate) fn new(limit_banner: libadwaita::Banner) -> Self {
        Self {
            limit_banner,
            listing: None,
        }
    }

    /// A search typed a key at a time would otherwise leave every
    /// earlier listing walking the keyspace for nobody.
    fn start_listing(&mut self) -> CancellationToken {
        let cancel = CancellationToken::new();
        if let Some(previous) = self.listing.replace(cancel.clone()) {
            previous.cancel();
        }
        cancel
    }

    pub(crate) fn stop_listing(&mut self) {
        if let Some(listing) = self.listing.take() {
            listing.cancel();
        }
    }
}

/// One listing that landed: which listing it was, whether a search
/// asked for it, and what it found or why it failed.
#[derive(Debug)]
pub(crate) struct KeysListed {
    pub(crate) read: u64,
    pub(crate) searched: bool,
    pub(crate) outcome: Result<ListedKeys, String>,
}

/// What one listing of a key-value engine's keys found.
#[derive(Debug)]
pub(crate) struct ListedKeys {
    pub(crate) index: SidebarIndex,
    /// Whether every key that matches is listed.
    pub(crate) complete: bool,
}

/// List the keys `scan` asks for and index them under `heading`. The
/// index is built on a blocking thread, as a catalog's is: a listing
/// holds thousands of keys.
async fn list_keys(
    session: Arc<Session>,
    tasks: Tasks,
    scan: KeyScan,
    heading: String,
    cancel: CancellationToken,
) -> Result<ListedKeys, String> {
    let listing = session
        .run_cancellable(OperationKind::Metadata, &cancel, move |lease, options| {
            let scan = scan.clone();
            async move { lease.scan_keys(&scan, options).await.map_err(OperationError::from) }
        })
        .await
        .map_err(|error| crate::ui::error_text::operation_error_message(&error))?;
    let complete = listing.complete;
    let index = tasks
        .spawn_blocking_task(move || SidebarIndex::keys(&listing.keys, heading))
        .await
        .map_err(|failure| failure.to_string())?;
    Ok(ListedKeys { index, complete })
}

/// The heading over the keys: the numbered database they are in.
fn database_heading(session: &Session) -> String {
    let number = database_number(session.database()).unwrap_or_default();
    crate::i18n::gettext_f("Database {number}", &[("number", &number.to_string())])
}

impl WorkspaceModel {
    /// List the keys the search matches, or every key, up to the
    /// sidebar's limit. Only the last listing asked for is shown.
    pub(in crate::ui::workspace) fn list_keys(&mut self) {
        let Some(session) = self.context.active.get() else {
            return;
        };
        let Some(keys) = self.keys.as_mut() else {
            return;
        };
        let cancel = keys.start_listing();
        self.sidebar_read += 1;
        let read = self.sidebar_read;
        let pattern = KeyScan::search(&self.table_search.text());
        let searched = pattern.is_some();
        let heading = database_heading(&session);
        let input = self.input.clone();
        let listing = list_keys(
            session,
            self.context.tasks.clone(),
            KeyScan::sidebar(pattern),
            heading,
            cancel,
        );
        crate::runtime::spawn_and_deliver(&self.context.tasks, listing, move |listed| {
            let outcome = listed.map_err(|failure| failure.to_string()).and_then(|listed| listed);
            input.deliver(WorkspaceInput::KeysListed(KeysListed {
                read,
                searched,
                outcome,
            }));
        });
    }

    /// Show the keys a listing found. A listing that failed leaves the
    /// keys on screen under the banner that says why.
    pub(in crate::ui::workspace) fn on_keys_listed(&mut self, listed: KeysListed) {
        let KeysListed {
            read,
            searched,
            outcome,
        } = listed;
        if read != self.sidebar_read {
            return;
        }
        match outcome {
            Ok(listed) => {
                self.catalog_banner.set_revealed(false);
                if let Some(keys) = self.keys.as_ref() {
                    keys.limit_banner.set_revealed(!listed.complete);
                }
                self.sidebar.show_keys(listed.index, searched);
                self.sync_sidebar_selection();
            }
            Err(message) => {
                let title = crate::i18n::gettext_f("Could not list the keys: {error}", &[("error", &message)]);
                self.catalog_banner.set_title(&title);
                self.catalog_banner.set_tooltip_text(Some(&title));
                self.catalog_banner.set_revealed(true);
            }
        }
    }
}
