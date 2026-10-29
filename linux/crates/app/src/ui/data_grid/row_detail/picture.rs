use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use gtk4::{gdk, gio, glib};
use tablepro_session::runtime::Tasks;

use super::RowDetailPane;

// The head glycin guesses the type from.
const SNIFF_BYTES: usize = u16::MAX as usize;
// A preview has no use for more, and the texture lives in this process: 256 MB at 8 bits a channel.
const MAX_PIXELS: u64 = 8192 * 8192;

// Spares copying a blob that is no image: glycin loads only `image/` types.
pub(super) fn may_be_image(bytes: &[u8]) -> bool {
    let head = bytes.get(..SNIFF_BYTES).unwrap_or(bytes);
    let (content_type, _) = gio::content_type_guess(None::<&str>, head);
    gio::content_type_get_mime_type(&content_type).is_some_and(|mime| mime.starts_with("image/"))
}

#[derive(Debug)]
pub struct PictureLoad {
    pub(super) cancellable: gio::Cancellable,
    tasks: Tasks,
}

impl PictureLoad {
    // glycin's cancel handler spawns on the runtime, which the GTK thread has not entered.
    pub fn stop(self) {
        let Self { cancellable, tasks } = self;
        drop(tasks.spawn_task(async move { cancellable.cancel() }));
    }
}

impl RowDetailPane {
    // Database bytes are untrusted, so they decode in glycin's sandbox, never in this process.
    pub(super) fn show_picture(&self, bytes: Option<Vec<u8>>) {
        let imp = self.imp();
        if let Some(superseded) = imp.picture_load.take() {
            superseded.stop();
        }
        let picture = imp.value_picture.get();
        picture.set_paintable(None::<&gdk::Paintable>);
        picture.set_visible(false);
        let Some(bytes) = bytes.filter(|bytes| may_be_image(bytes)) else {
            return;
        };
        let Some(tasks) = self
            .grid()
            .and_then(|grid| grid.config().map(|config| config.tasks.clone()))
        else {
            return;
        };
        let cancellable = gio::Cancellable::new();
        let decode = tasks.spawn_task(decode(glib::Bytes::from_owned(bytes), cancellable.clone()));
        imp.picture_load.replace(Some(PictureLoad {
            cancellable: cancellable.clone(),
            tasks,
        }));
        let pane = self.downgrade();
        glib::spawn_future_local(async move {
            let decoded = decode.await;
            let Some(pane) = pane.upgrade() else {
                return;
            };
            // The stop of a superseded decode lands on the runtime later than this may.
            let current = pane
                .imp()
                .picture_load
                .borrow()
                .as_ref()
                .is_some_and(|load| load.cancellable == cancellable);
            if !current {
                return;
            }
            pane.imp().picture_load.take();
            let texture = match decoded {
                Ok(Ok(texture)) => texture,
                Ok(Err(error)) => {
                    tracing::debug!(%error, "the value is no image glycin can show");
                    return;
                }
                Err(failure) => {
                    tracing::warn!(%failure, "the value's picture could not be decoded");
                    return;
                }
            };
            let picture = pane.imp().value_picture.get();
            picture.set_paintable(texture.as_ref());
            picture.set_visible(texture.is_some());
        });
    }
}

async fn decode(
    bytes: glib::Bytes,
    cancellable: gio::Cancellable,
) -> Result<Option<gdk::Texture>, Box<glycin::ErrorCtx>> {
    let mechanism = glycin::SandboxSelector::Auto.determine_sandbox_mechanism().await;
    let Some(sandbox) = sandbox(mechanism, cfg!(test)) else {
        tracing::debug!("no sandbox to decode a value's picture in");
        return Ok(None);
    };
    let mut loader = glycin::Loader::new_bytes(bytes);
    loader.cancellable(cancellable).sandbox_selector(sandbox);
    let image = loader.load().await.map_err(Box::new)?;
    let details = image.details();
    if u64::from(details.width()) * u64::from(details.height()) > MAX_PIXELS {
        return Ok(None);
    }
    Ok(Some(image.next_frame().await.map_err(Box::new)?.texture()))
}

// glycin's Auto falls back to no sandbox where bwrap cannot make namespaces, and database bytes must
// never reach a decoder outside one. Tests allow it: CI runs them in containers.
pub(super) fn sandbox(mechanism: glycin::SandboxMechanism, unsandboxed: bool) -> Option<glycin::SandboxSelector> {
    (mechanism != glycin::SandboxMechanism::NotSandboxed || unsandboxed).then(|| mechanism.into_selector())
}
