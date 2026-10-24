use std::cell::RefCell;

use gtk4 as gtk;
use gtk4::prelude::*;

use super::code_block::{BlockHooks, CodeBlock};
use super::markdown::{Block, blocks};

enum Shown {
    Text(gtk::Label),
    /// With the language its fence named, which a block still streaming
    /// can have only part of.
    Code(CodeBlock, Option<String>),
}

/// A reply's text, laid out from its Markdown. As the reply streams,
/// each block that is still the same kind is updated in place, so a
/// code block being written keeps its widget.
pub(crate) struct MessageView {
    root: gtk::Box,
    shown: RefCell<Vec<Shown>>,
    hooks: BlockHooks,
}

impl MessageView {
    pub(crate) fn new(hooks: BlockHooks) -> Self {
        Self {
            root: gtk::Box::new(gtk::Orientation::Vertical, 10),
            shown: RefCell::new(Vec::new()),
            hooks,
        }
    }

    pub(crate) fn widget(&self) -> &gtk::Box {
        &self.root
    }

    pub(crate) fn set_markdown(&self, markdown: &str) {
        let wanted = blocks(markdown);
        let mut shown = self.shown.borrow_mut();
        let mut kept = 0;
        for (block, existing) in wanted.iter().zip(shown.iter()) {
            match (block, existing) {
                (Block::Text(markup), Shown::Text(label)) => {
                    if label.label() != markup.as_str() {
                        label.set_markup(markup);
                    }
                }
                (Block::Code { code, language }, Shown::Code(view, shown)) if language == shown => view.set_code(code),
                _ => break,
            }
            kept += 1;
        }
        for removed in shown.drain(kept..) {
            match removed {
                Shown::Text(label) => self.root.remove(&label),
                Shown::Code(view, _) => self.root.remove(view.widget()),
            }
        }
        for block in wanted.into_iter().skip(kept) {
            let added = match block {
                Block::Text(markup) => Shown::Text(text_label(&markup)),
                Block::Code { language, code } => {
                    Shown::Code(CodeBlock::new(&code, language.as_deref(), &self.hooks), language)
                }
            };
            match &added {
                Shown::Text(label) => self.root.append(label),
                Shown::Code(view, _) => self.root.append(view.widget()),
            }
            shown.push(added);
        }
    }
}

fn text_label(markup: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .use_markup(true)
        .wrap(true)
        .wrap_mode(gtk::pango::WrapMode::WordChar)
        .xalign(0.0)
        .selectable(true)
        .build();
    label.set_markup(markup);
    label
}

#[cfg(test)]
mod tests {
    use std::rc::Rc;

    use super::*;

    fn view(settings: &crate::test_support::MemorySettings) -> MessageView {
        MessageView::new(BlockHooks {
            settings: settings.get().clone(),
            insert: Rc::new(|_| {}),
            toast: Rc::new(|_| {}),
        })
    }

    fn children(view: &MessageView) -> Vec<gtk::Widget> {
        let mut children = Vec::new();
        let mut child = view.widget().first_child();
        while let Some(widget) = child {
            child = widget.next_sibling();
            children.push(widget);
        }
        children
    }

    #[gtk4::test]
    fn a_streaming_code_block_keeps_its_widget() {
        let settings = crate::test_support::MemorySettings::new();
        let view = view(&settings);

        view.set_markdown("Try:\n\n```sql\nSELECT");
        let before = children(&view);
        view.set_markdown("Try:\n\n```sql\nSELECT 1;\n```\n\nDone.");
        let after = children(&view);

        assert_eq!(before.len(), 2);
        assert_eq!(after.len(), 3);
        assert_eq!(before[1], after[1], "the code block was built again");
        let done = after[2].clone().downcast::<gtk::Label>().expect("a label");
        assert_eq!(done.label(), "Done.");
    }

    #[gtk4::test]
    fn text_that_turns_into_another_kind_is_rebuilt() {
        let settings = crate::test_support::MemorySettings::new();
        let view = view(&settings);

        view.set_markdown("one");
        view.set_markdown("```\ncode\n```");

        let shown = children(&view);
        assert_eq!(shown.len(), 1);
        assert!(!shown[0].is::<gtk::Label>());
    }
}
