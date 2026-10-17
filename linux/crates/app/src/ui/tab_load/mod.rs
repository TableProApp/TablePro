//! How a tab shows what it reads: a spinner until the first read lands,
//! the content from then on, and an error page only while there is
//! nothing to show. A read that fails with content on screen leaves the
//! content there under a banner, so a blip never blanks a tab.

mod content_load;
mod first_load;
mod load_failure;
mod load_presentation;
mod stale_banner;

pub(crate) use self::content_load::ContentLoad;
pub(crate) use self::first_load::{FirstLoad, start_first_load};
pub(crate) use self::load_failure::LoadFailure;
pub(crate) use self::load_presentation::{ContentPage, LoadPresentation};
pub(crate) use self::stale_banner::StaleBanner;
