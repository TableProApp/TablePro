use std::rc::Rc;

use gtk4 as gtk;
use gtk4::prelude::*;
use libadwaita as adw;

use crate::ui::handler_guard::HandlerGuard;

/// What a code block's buttons reach beyond it.
#[derive(Clone)]
pub(crate) struct BlockHooks {
    pub settings: Rc<tablepro_storage::AppSettings>,
    /// Put the code in the editor.
    pub insert: Rc<dyn Fn(String)>,
    pub toast: Rc<dyn Fn(String)>,
}

/// One code block of a reply: read-only, highlighted as the editor is,
/// with Copy and Insert.
pub(crate) struct CodeBlock {
    root: gtk::Box,
    buffer: sourceview5::Buffer,
    code: Rc<std::cell::RefCell<String>>,
    _theme: [HandlerGuard; 2],
}

impl CodeBlock {
    pub(crate) fn new(code: &str, language: Option<&str>, hooks: &BlockHooks) -> Self {
        let sql = language.is_none_or(|language| matches!(language, "sql" | "mysql" | "postgresql" | "sqlite"));
        let buffer = match sql
            .then(|| sourceview5::LanguageManager::default().language("sql"))
            .flatten()
        {
            Some(sql) => sourceview5::Buffer::with_language(&sql),
            None => sourceview5::Buffer::new(None),
        };
        buffer.set_text(code);
        let view = sourceview5::View::with_buffer(&buffer);
        view.set_editable(false);
        view.set_cursor_visible(false);
        view.set_monospace(true);
        view.set_wrap_mode(gtk::WrapMode::WordChar);
        view.set_top_margin(8);
        view.set_bottom_margin(8);
        view.set_left_margin(10);
        view.set_right_margin(10);
        // Read-only, so it takes no input method, which would keep it
        // alive after the reply is gone.
        view.set_im_module(Some("gtk-im-context-none"));
        view.upcast_ref::<gtk::Widget>()
            .update_property(&[gtk::accessible::Property::Label(&crate::i18n::gettext("Code"))]);
        crate::ui::style_scheme_resolver::apply(&view, &hooks.settings.style_scheme());
        let style_manager = adw::StyleManager::default();
        let settings = Rc::downgrade(&hooks.settings);
        let themed = view.downgrade();
        let theme = style_manager.connect_dark_notify(move |_| {
            if let (Some(view), Some(settings)) = (themed.upgrade(), settings.upgrade()) {
                crate::ui::style_scheme_resolver::apply(&view, &settings.style_scheme());
            }
        });
        let themed = view.downgrade();
        let scheme = hooks.settings.gio().connect_changed(
            Some(tablepro_storage::settings::keys::STYLE_SCHEME),
            move |settings, key| {
                if let Some(view) = themed.upgrade() {
                    crate::ui::style_scheme_resolver::apply(&view, &settings.string(key));
                }
            },
        );

        let code = Rc::new(std::cell::RefCell::new(code.to_owned()));
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        header.set_margin_start(10);
        header.set_margin_end(4);
        header.set_margin_top(4);
        let name = gtk::Label::builder()
            .label(language.unwrap_or_default().to_uppercase())
            .xalign(0.0)
            .hexpand(true)
            .build();
        name.add_css_class("caption");
        name.add_css_class("dim-label");
        header.append(&name);
        header.append(&copy_button(&code, hooks));
        header.append(&insert_button(&code, hooks));

        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("card");
        root.set_overflow(gtk::Overflow::Hidden);
        root.append(&header);
        root.append(&view);
        Self {
            root,
            buffer,
            code,
            _theme: [
                HandlerGuard::new(&style_manager, theme),
                HandlerGuard::new(hooks.settings.gio(), scheme),
            ],
        }
    }

    pub(crate) fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// Show `code` in place of what the block shows, as a reply streams.
    pub(crate) fn set_code(&self, code: &str) {
        if *self.code.borrow() == code {
            return;
        }
        self.code.replace(code.to_owned());
        self.buffer.set_text(code);
    }
}

fn copy_button(code: &Rc<std::cell::RefCell<String>>, hooks: &BlockHooks) -> gtk::Button {
    let button = gtk::Button::from_icon_name(crate::ui::icons::EDIT_COPY);
    button.add_css_class("flat");
    crate::ui::a11y::describe_icon_button(&button, &crate::i18n::gettext("Copy"), None);
    let (code, toast) = (code.clone(), hooks.toast.clone());
    button.connect_clicked(move |button| {
        crate::ui::clipboard::copy_text(button, code.borrow().clone(), |message| toast(message.to_owned()));
    });
    button
}

fn insert_button(code: &Rc<std::cell::RefCell<String>>, hooks: &BlockHooks) -> gtk::Button {
    let button = gtk::Button::with_label(&crate::i18n::gettext("Insert"));
    button.add_css_class("flat");
    button.set_tooltip_text(Some(&crate::i18n::gettext("Insert Into the Editor")));
    let (code, insert) = (code.clone(), hooks.insert.clone());
    button.connect_clicked(move |_| insert(code.borrow().clone()));
    button
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;

    use super::*;

    #[gtk4::test]
    fn insert_hands_over_the_code_as_it_now_reads() {
        let settings = crate::test_support::MemorySettings::new();
        let inserted = Rc::new(RefCell::new(None));
        let seen = inserted.clone();
        let hooks = BlockHooks {
            settings: settings.get().clone(),
            insert: Rc::new(move |code| {
                seen.replace(Some(code));
            }),
            toast: Rc::new(|_| {}),
        };
        let block = CodeBlock::new("SELECT", Some("sql"), &hooks);

        block.set_code("SELECT 1;");
        let insert = crate::test_support::descendants(block.widget())
            .into_iter()
            .filter_map(|widget| widget.downcast::<gtk::Button>().ok())
            .find(|button| button.label().as_deref() == Some("Insert"))
            .expect("the Insert button");
        insert.emit_clicked();

        assert_eq!(inserted.borrow().as_deref(), Some("SELECT 1;"));
        assert!(crate::test_support::unlabelled_icon_buttons(block.widget()).is_empty());
    }
}
