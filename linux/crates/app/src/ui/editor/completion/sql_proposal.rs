use std::cmp::Ordering;

use gtk4::glib;
use gtk4::subclass::prelude::*;

use super::proposal_kind::ProposalKind;
use super::sql_proposal_imp as imp;

glib::wrapper! {
    /// One entry of the editor's completion list.
    pub struct SqlProposal(ObjectSubclass<imp::SqlProposal>)
        @implements sourceview5::CompletionProposal;
}

impl SqlProposal {
    pub fn new(kind: ProposalKind, label: &str, insert_text: &str) -> Self {
        let proposal: Self = glib::Object::new();
        let imp = proposal.imp();
        let _ = imp.kind.set(kind);
        let _ = imp.label.set(label.to_owned());
        let _ = imp.insert_text.set(insert_text.to_owned());
        proposal
    }

    pub fn keyword(keyword: &str) -> Self {
        Self::new(ProposalKind::Keyword, keyword, keyword)
    }

    pub fn kind(&self) -> &ProposalKind {
        static KEYWORD: ProposalKind = ProposalKind::Keyword;
        self.imp().kind.get().unwrap_or(&KEYWORD)
    }

    pub fn label(&self) -> &str {
        self.imp().label.get().map_or("", String::as_str)
    }

    /// The text the list shows while `word` is typed: a keyword follows
    /// the case the user writes keywords in.
    pub fn shown_text(&self, word: &str) -> String {
        self.cased(self.label(), word)
    }

    /// The text that replaces `word` when the proposal is chosen.
    pub fn insert_text(&self, word: &str) -> String {
        let text = self.imp().insert_text.get().map_or("", String::as_str);
        self.cased(text, word)
    }

    pub fn priority(&self) -> u32 {
        self.imp().priority.get()
    }

    pub fn set_priority(&self, priority: u32) {
        self.imp().priority.set(priority);
    }

    /// The list order: the closest match first, then what the
    /// statement names before keywords. Ties keep the catalog's order,
    /// which lists a table's columns as the table defines them.
    pub fn compare(&self, other: &Self) -> Ordering {
        self.priority()
            .cmp(&other.priority())
            .then_with(|| self.kind().rank().cmp(&other.kind().rank()))
    }

    fn cased(&self, text: &str, word: &str) -> String {
        let lowercase = word.chars().any(char::is_lowercase) && !word.chars().any(char::is_uppercase);
        if self.kind().is_keyword() && lowercase {
            text.to_lowercase()
        } else {
            text.to_owned()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_keyword_follows_the_case_typed() {
        let select = SqlProposal::keyword("SELECT");

        assert_eq!(select.insert_text("sel"), "select");
        assert_eq!(select.insert_text("SEL"), "SELECT");
        assert_eq!(select.insert_text("Sel"), "SELECT");
        assert_eq!(select.insert_text(""), "SELECT");
        assert_eq!(select.shown_text("se"), "select");
    }

    #[test]
    fn an_identifier_keeps_its_case() {
        let table = SqlProposal::new(ProposalKind::Table, "Users", "\"Users\"");

        assert_eq!(table.insert_text("us"), "\"Users\"");
        assert_eq!(table.shown_text("us"), "Users");
    }

    #[test]
    fn closer_matches_sort_first_then_by_kind() {
        let keyword = SqlProposal::keyword("USING");
        let table = SqlProposal::new(ProposalKind::Table, "users", "users");
        keyword.set_priority(3);
        table.set_priority(3);

        assert_eq!(table.compare(&keyword), Ordering::Less);
        keyword.set_priority(1);
        assert_eq!(table.compare(&keyword), Ordering::Greater);
    }
}
