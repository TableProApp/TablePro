use gtk4 as gtk;
use gtk4::prelude::*;

/// Two toolkit cycles keep a closed text view alive (docs/toolkit-workarounds.md): dropping the input method
/// breaks IBus's, and an empty buffer frees the text where GtkSourceView's still holds the view.
pub(crate) fn release(view: &impl IsA<gtk::TextView>) {
    let view = view.as_ref();
    view.set_im_module(Some(NO_INPUT_METHOD));
    let empty: gtk::TextBuffer = match view.downcast_ref::<sourceview5::View>() {
        Some(_) => sourceview5::Buffer::new(None).upcast(),
        None => gtk::TextBuffer::new(None),
    };
    view.set_buffer(Some(&empty));
}

const NO_INPUT_METHOD: &str = "gtk-im-context-none";

#[cfg(test)]
mod tests {
    use super::*;

    #[gtk4::test]
    fn a_released_view_holds_no_text_and_no_input_method() {
        let view = sourceview5::View::new();
        view.buffer().set_text("SELECT secret FROM vault;");

        release(&view);

        assert_eq!(view.im_module().as_deref(), Some(NO_INPUT_METHOD));
        assert_eq!(view.buffer().char_count(), 0);
        assert!(
            view.buffer().is::<sourceview5::Buffer>(),
            "a source view lost its source buffer"
        );
    }

    #[gtk4::test]
    fn a_released_plain_view_is_finalized_once_dropped() {
        let view = gtk::TextView::new();
        view.buffer().set_text("draft");
        let weak = view.downgrade();

        release(&view);
        drop(view);
        crate::test_support::drain_main_context();

        assert!(weak.upgrade().is_none(), "the text view outlived its last reference");
    }
}
