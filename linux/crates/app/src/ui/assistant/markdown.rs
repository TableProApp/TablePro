//! A reply's Markdown as GTK shows it: runs of text as Pango markup for
//! a label, and each code block on its own, to copy or insert.

use gtk4::glib;
use pulldown_cmark::{CodeBlockKind, Event, Options, Parser, Tag, TagEnd};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Block {
    /// Pango markup.
    Text(String),
    Code {
        language: Option<String>,
        code: String,
    },
}

pub(crate) fn blocks(markdown: &str) -> Vec<Block> {
    let mut writer = Writer::default();
    let options = Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(markdown, options) {
        writer.event(event);
    }
    writer.finish()
}

#[derive(Default)]
struct Writer {
    blocks: Vec<Block>,
    text: String,
    /// The markup open at this point, each with its closing tag, closed
    /// before a code block and opened again after it, so every text
    /// block is markup Pango reads on its own.
    open: Vec<(String, &'static str)>,
    code: Option<(Option<String>, String)>,
    /// The open lists, each with the number its next item takes.
    lists: Vec<Option<u64>>,
    /// Whether each open link was written as one: only http and https
    /// links are, so a reply cannot hand the desktop another scheme.
    links: Vec<bool>,
    cells: usize,
}

impl Writer {
    fn event(&mut self, event: Event<'_>) {
        if let Some((_, code)) = self.code.as_mut() {
            match event {
                Event::Text(text) => code.push_str(&text),
                Event::End(TagEnd::CodeBlock) => self.end_code(),
                _ => {}
            }
            return;
        }
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text.push_str(&glib::markup_escape_text(&text)),
            Event::Code(code) => {
                self.text.push_str("<tt>");
                self.text.push_str(&glib::markup_escape_text(&code));
                self.text.push_str("</tt>");
            }
            Event::Html(html) | Event::InlineHtml(html) => self.text.push_str(&glib::markup_escape_text(&html)),
            Event::SoftBreak | Event::HardBreak => self.text.push('\n'),
            Event::Rule => self.gap(),
            Event::TaskListMarker(done) => self.text.push_str(if done { "☑ " } else { "☐ " }),
            _ => {}
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {
                if !self.in_item_start() {
                    self.gap();
                }
            }
            Tag::Heading { .. } => {
                self.gap();
                self.push_open("<span weight=\"bold\" size=\"larger\">".to_owned(), "</span>");
            }
            Tag::BlockQuote(_) => {
                self.gap();
                self.push_open("<i>".to_owned(), "</i>");
            }
            Tag::CodeBlock(kind) => self.start_code(kind),
            Tag::List(first) => {
                if self.lists.is_empty() {
                    self.gap();
                }
                self.lists.push(first);
            }
            Tag::Item => self.item(),
            Tag::Emphasis => self.push_open("<i>".to_owned(), "</i>"),
            Tag::Strong => self.push_open("<b>".to_owned(), "</b>"),
            Tag::Strikethrough => self.push_open("<s>".to_owned(), "</s>"),
            Tag::Link { dest_url, .. } => {
                let web = dest_url.starts_with("https://") || dest_url.starts_with("http://");
                if web {
                    self.push_open(format!("<a href=\"{}\">", glib::markup_escape_text(&dest_url)), "</a>");
                }
                self.links.push(web);
            }
            Tag::Table(_) => {
                self.gap();
                self.push_open("<tt>".to_owned(), "</tt>");
            }
            Tag::TableHead => {
                self.cells = 0;
                self.push_open("<b>".to_owned(), "</b>");
            }
            Tag::TableRow => {
                self.text.push('\n');
                self.cells = 0;
            }
            Tag::TableCell => {
                if self.cells > 0 {
                    self.text.push_str(" | ");
                }
                self.cells += 1;
            }
            _ => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Heading(_)
            | TagEnd::BlockQuote(_)
            | TagEnd::Emphasis
            | TagEnd::Strong
            | TagEnd::Strikethrough
            | TagEnd::TableHead
            | TagEnd::Table => self.pop_open(),
            TagEnd::List(_) => {
                self.lists.pop();
            }
            // Popped whether or not it was written as a link.
            TagEnd::Link if self.links.pop() == Some(true) => self.pop_open(),
            _ => {}
        }
    }

    fn push_open(&mut self, open: String, close: &'static str) {
        self.text.push_str(&open);
        self.open.push((open, close));
    }

    fn pop_open(&mut self) {
        if let Some((_, close)) = self.open.pop() {
            self.text.push_str(close);
        }
    }

    fn start_code(&mut self, kind: CodeBlockKind<'_>) {
        self.flush_text();
        let language = match kind {
            CodeBlockKind::Fenced(info) => info
                .split_whitespace()
                .next()
                .map(str::to_lowercase)
                .filter(|language| !language.is_empty()),
            CodeBlockKind::Indented => None,
        };
        self.code = Some((language, String::new()));
    }

    fn item(&mut self) {
        if self.has_text() && !self.text.ends_with('\n') {
            self.text.push('\n');
        }
        let depth = self.lists.len().saturating_sub(1);
        self.text.push_str(&"    ".repeat(depth));
        match self.lists.last_mut() {
            Some(Some(number)) => {
                self.text.push_str(&format!("{number}. "));
                *number += 1;
            }
            _ => self.text.push_str("• "),
        }
    }

    /// A paragraph inside a list item starts on the item's own line.
    fn in_item_start(&self) -> bool {
        !self.lists.is_empty() && (self.text.ends_with("• ") || self.text.ends_with(". "))
    }

    /// Whether the text holds anything to show beyond markup. Text is
    /// escaped as it comes, so every `<` in it opens a tag.
    fn has_text(&self) -> bool {
        let mut in_tag = false;
        self.text.chars().any(|c| match c {
            '<' => {
                in_tag = true;
                false
            }
            '>' if in_tag => {
                in_tag = false;
                false
            }
            c => !in_tag && !c.is_whitespace(),
        })
    }

    fn gap(&mut self) {
        if self.has_text() && !self.text.ends_with("\n\n") {
            self.text
                .push_str(if self.text.ends_with('\n') { "\n" } else { "\n\n" });
        }
    }

    /// End the text block before a code block: the markup still open
    /// is closed here and opened again after the code.
    fn flush_text(&mut self) {
        let shows = self.has_text();
        let mut text = std::mem::take(&mut self.text);
        for (_, close) in self.open.iter().rev() {
            text.push_str(close);
        }
        let trimmed = text.trim();
        if shows && !trimmed.is_empty() {
            self.blocks.push(Block::Text(trimmed.to_owned()));
        }
    }

    fn end_code(&mut self) {
        if let Some((language, code)) = self.code.take() {
            let code = code.trim_end_matches('\n').to_owned();
            self.blocks.push(Block::Code { language, code });
            for (open, _) in &self.open {
                self.text.push_str(open);
            }
        }
    }

    fn finish(mut self) -> Vec<Block> {
        // A reply still streaming can end inside an open code block.
        self.end_code();
        self.flush_text();
        self.blocks
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn markup(blocks: &[Block]) -> Vec<String> {
        blocks
            .iter()
            .filter_map(|block| match block {
                Block::Text(text) => Some(text.clone()),
                Block::Code { .. } => None,
            })
            .collect()
    }

    #[test]
    fn text_and_code_blocks_come_out_in_order() {
        let reply = "Run this:\n\n```sql\nSELECT *\nFROM orders;\n```\n\nIt reads **every** row.";

        let blocks = blocks(reply);

        assert_eq!(
            blocks,
            vec![
                Block::Text("Run this:".to_owned()),
                Block::Code {
                    language: Some("sql".to_owned()),
                    code: "SELECT *\nFROM orders;".to_owned(),
                },
                Block::Text("It reads <b>every</b> row.".to_owned()),
            ]
        );
    }

    #[test]
    fn markup_characters_in_the_text_stay_text() {
        let blocks = blocks("Use `a < b` & <b>not this</b>");

        assert_eq!(
            markup(&blocks),
            ["Use <tt>a &lt; b</tt> &amp; &lt;b&gt;not this&lt;/b&gt;"]
        );
    }

    #[test]
    fn lists_keep_their_bullets_and_numbers() {
        let blocks = blocks("Steps:\n\n1. Join\n2. Filter\n   - by date\n\n- one\n- two");

        assert_eq!(
            markup(&blocks),
            ["Steps:\n\n1. Join\n2. Filter\n    • by date\n\n• one\n• two"]
        );
    }

    #[test]
    fn only_web_links_become_links() {
        let blocks = blocks("[docs](https://example.com/a?b=1&c=2) and [run](file:///etc/passwd)");

        assert_eq!(
            markup(&blocks),
            ["<a href=\"https://example.com/a?b=1&amp;c=2\">docs</a> and run"]
        );
    }

    #[test]
    fn a_code_block_still_open_while_streaming_is_shown() {
        let blocks = blocks("Here:\n```sql\nSELECT 1");

        assert_eq!(
            blocks.last(),
            Some(&Block::Code {
                language: Some("sql".to_owned()),
                code: "SELECT 1".to_owned()
            })
        );
    }

    #[test]
    fn markup_open_around_a_code_block_is_closed_and_opened_again() {
        let blocks = blocks("> Try this:\n>\n> ```sql\n> SELECT 1;\n> ```\n>\n> then this.");

        assert_eq!(
            blocks,
            vec![
                Block::Text("<i>Try this:</i>".to_owned()),
                Block::Code {
                    language: Some("sql".to_owned()),
                    code: "SELECT 1;".to_owned(),
                },
                Block::Text("<i>then this.</i>".to_owned()),
            ]
        );
    }

    /// GtkLabel reads links itself and hands Pango the rest, so a label
    /// is what checks it.
    #[gtk4::test]
    fn every_markup_written_parses() {
        let replies = [
            "> quoted\n>\n> ```\ncode\n```\n> after",
            "**bold [link](https://a.example) `x`**\n\n```\ny\n```",
            "# Title\n\nSome *emphasis* and **strong** and ~~gone~~.",
            "> quoted\n> lines\n\n| a | b |\n|---|---|\n| 1 | 2 |",
            "- [x] done\n- [ ] open\n\n---\n\nend",
            "Unclosed **bold and `code",
            "<script>alert(1)</script>",
        ];
        for reply in replies {
            for text in markup(&blocks(reply)) {
                let label = gtk4::Label::new(None);
                label.set_markup(&text);
                assert!(
                    !label.text().is_empty(),
                    "{reply:?} gave markup a label cannot read: {text}"
                );
            }
        }
    }
}
