use std::path::Path;

use oo7::AsAttributes;
use oo7::file::{Item as FileItem, UnlockedKeyring};
use tokio::sync::Mutex;

use super::portal;

// Boxed: oo7::Error is large enough that clippy refuses it as an Err variant.
pub(super) type Result<T> = std::result::Result<T, Box<oo7::Error>>;

// The two backends oo7's Keyring::new picks between. Inside a sandbox the store opens the file keyring
// itself, since oo7 0.6 gets the portal's key through ashpd's retrieve, which hangs on a refused request.
pub(super) enum Backend {
    Service(oo7::Keyring),
    File {
        keyring: UnlockedKeyring,
        // A relabel rewrites the item with the secret it read, so a store landing in between would be
        // undone. The file is local, so holding this never waits on the user.
        writes: Mutex<()>,
    },
}

impl Backend {
    pub(super) async fn open() -> Result<Self> {
        if !oo7::ashpd::is_sandboxed() {
            return Ok(Self::Service(oo7::Keyring::new().await?));
        }
        let secret = portal::retrieve_secret()
            .await
            .map_err(|error| file_error(error.into()))?;
        // The same file and key oo7's Keyring::new opens, so the passwords earlier builds saved still read.
        let path = oo7::file::api::Keyring::default_path().map_err(file_error)?;
        Self::open_file(path, secret).await
    }

    pub(super) async fn open_file(path: impl AsRef<Path>, secret: oo7::Secret) -> Result<Self> {
        Ok(Self::File {
            keyring: UnlockedKeyring::load(path, secret).await.map_err(file_error)?,
            writes: Mutex::new(()),
        })
    }

    // Unlocking before the read is what turns a silent empty result into a prompt the user can answer.
    // A file keyring opened with the portal's key is already unlocked.
    pub(super) async fn unlock(&self) -> Result<()> {
        if let Self::Service(keyring) = self
            && keyring.is_locked().await?
        {
            keyring.unlock().await?;
        }
        Ok(())
    }

    pub(super) async fn find_secret(&self, attributes: &impl AsAttributes) -> Result<Option<oo7::Secret>> {
        match self {
            Self::Service(keyring) => {
                let Some(item) = keyring.search_items(attributes).await?.into_iter().next() else {
                    return Ok(None);
                };
                // An item can be locked even when the collection is not.
                if item.is_locked().await? {
                    item.unlock().await?;
                }
                Ok(Some(item.secret().await?))
            }
            Self::File { keyring, .. } => match keyring
                .search_items(attributes)
                .await
                .map_err(file_error)?
                .into_iter()
                .next()
            {
                None => Ok(None),
                Some(FileItem::Unlocked(item)) => Ok(Some(item.secret())),
                Some(FileItem::Locked(_)) => Err(file_error(oo7::file::Error::Locked)),
            },
        }
    }

    pub(super) async fn store(&self, label: &str, attributes: &impl AsAttributes, secret: oo7::Secret) -> Result<()> {
        match self {
            Self::Service(keyring) => Ok(keyring.create_item(label, attributes, secret, true).await?),
            Self::File { keyring, writes } => {
                let _writing = writes.lock().await;
                keyring
                    .create_item(label, attributes, secret, true)
                    .await
                    .map_err(file_error)?;
                Ok(())
            }
        }
    }

    pub(super) async fn relabel(&self, attributes: &impl AsAttributes, label: &str) -> Result<()> {
        match self {
            Self::Service(keyring) => {
                for item in keyring.search_items(attributes).await? {
                    item.set_label(label).await?;
                }
            }
            // As oo7's Item::set_label does for a file item: the keyring is written whole, so the item
            // is replaced with its new label.
            Self::File { keyring, writes } => {
                let _writing = writes.lock().await;
                for item in keyring.search_items(attributes).await.map_err(file_error)? {
                    let FileItem::Unlocked(mut item) = item else {
                        return Err(file_error(oo7::file::Error::Locked));
                    };
                    item.set_label(label);
                    keyring
                        .create_item(item.label(), item.attributes(), item.secret(), true)
                        .await
                        .map_err(file_error)?;
                }
            }
        }
        Ok(())
    }

    pub(super) async fn delete(&self, attributes: &impl AsAttributes) -> Result<()> {
        match self {
            Self::Service(keyring) => Ok(keyring.delete(attributes).await?),
            Self::File { keyring, writes } => {
                let _writing = writes.lock().await;
                Ok(keyring.delete(attributes).await.map_err(file_error)?)
            }
        }
    }
}

fn file_error(error: oo7::file::Error) -> Box<oo7::Error> {
    Box::new(oo7::Error::File(error))
}
