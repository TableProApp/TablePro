use std::sync::Arc;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::runtime::Tasks;

use super::fuzzy;
use super::proposal_kind::ProposalKind;
use super::proposal_list_imp as imp;
use super::sql_proposal::SqlProposal;
use crate::services::snippet_library::OfferedSnippet;

/// What the completion can offer, before it is a row of the list. Built
/// with the catalog read, away from the GTK thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub kind: ProposalKind,
    pub label: String,
    pub insert_text: String,
}

impl Candidate {
    pub fn new(kind: ProposalKind, label: &str, insert_text: &str) -> Self {
        Self {
            kind,
            label: label.to_owned(),
            insert_text: insert_text.to_owned(),
        }
    }

    pub fn keyword(keyword: &str) -> Self {
        Self::new(ProposalKind::Keyword, keyword, keyword)
    }

    /// Matched by its trigger. It inserts through the view rather than
    /// as text, so it has none.
    pub fn snippet(snippet: OfferedSnippet) -> Self {
        Self {
            label: snippet.trigger.clone(),
            insert_text: String::new(),
            kind: ProposalKind::Snippet(snippet),
        }
    }

    pub(super) fn proposal(&self) -> SqlProposal {
        SqlProposal::new(self.kind.clone(), &self.label, &self.insert_text)
    }
}

/// The candidates in the order the list shows them for one word: the
/// closest match first, then what the statement names before keywords,
/// ties in the catalog's order, which lists a table's columns as the
/// table defines them. Worked out away from the GTK thread.
#[derive(Debug)]
pub struct Ranking {
    candidates: Arc<[Candidate]>,
    needle: String,
    ranked: Vec<u32>,
}

impl Ranking {
    /// `needle` is the word typed so far, casefolded. With nothing typed
    /// every candidate matches equally, since the matcher would rank by
    /// length alone and put every short keyword above the columns.
    pub fn new(candidates: Arc<[Candidate]>, needle: &str) -> Self {
        let mut scored: Vec<(u32, u8, u32)> = candidates
            .iter()
            .enumerate()
            .filter_map(|(at, candidate)| {
                let score = if needle.is_empty() {
                    0
                } else {
                    fuzzy::fuzzy_match(&candidate.label, needle)?
                };
                Some((score, candidate.kind.rank(), u32::try_from(at).ok()?))
            })
            .collect();
        scored.sort_unstable();
        Self {
            ranked: scored.into_iter().map(|(_, _, at)| at).collect(),
            candidates,
            needle: needle.to_owned(),
        }
    }
}

glib::wrapper! {
    /// The completion's rows: the candidates the typed word matches, each
    /// made a proposal only when GtkSourceView shows it. A catalog of
    /// 50,000 tables would otherwise be 50,000 objects sorted through a
    /// comparison call each, on every key.
    pub struct ProposalList(ObjectSubclass<imp::ProposalList>)
        @implements gio::ListModel;
}

impl ProposalList {
    /// A list that ranks again for each word on `tasks`' blocking
    /// threads, or on the GTK thread without them.
    pub fn new(ranking: Ranking, tasks: Option<Tasks>) -> Self {
        let list: Self = glib::Object::new();
        let imp = list.imp();
        imp.candidates.replace(ranking.candidates);
        imp.needle.replace(ranking.needle);
        imp.ranked.replace(ranking.ranked);
        if let Some(tasks) = tasks {
            let _ = imp.tasks.set(tasks);
        }
        list
    }

    /// Rank again for the word now typed, `needle` casefolded. The list
    /// changes once the ranking lands, unless a later word overtook it.
    pub fn set_needle(&self, needle: &str) {
        let imp = self.imp();
        if *imp.needle.borrow() == needle {
            return;
        }
        imp.needle.replace(needle.to_owned());
        let generation = imp.generation.get() + 1;
        imp.generation.set(generation);
        let candidates = imp.candidates.borrow().clone();
        let needle = needle.to_owned();
        let Some(tasks) = imp.tasks.get() else {
            self.show(Ranking::new(candidates, &needle).ranked);
            return;
        };
        let ranking = tasks.spawn_blocking_task(move || Ranking::new(candidates, &needle));
        let list = self.downgrade();
        glib::spawn_future_local(async move {
            let Ok(ranking) = ranking.await else {
                return;
            };
            if let Some(list) = list.upgrade()
                && list.imp().generation.get() == generation
            {
                list.show(ranking.ranked);
            }
        });
    }

    /// One change for the whole list, which GtkSourceView answers by
    /// drawing the rows on screen again.
    fn show(&self, ranked: Vec<u32>) {
        let imp = self.imp();
        if *imp.ranked.borrow() == ranked {
            return;
        }
        let removed = self.n_items();
        let added = u32::try_from(ranked.len()).unwrap_or(u32::MAX);
        imp.ranked.replace(ranked);
        self.items_changed(0, removed, added);
    }
}

#[cfg(test)]
mod tests {
    use std::cell::RefCell;
    use std::rc::Rc;
    use std::time::Duration;

    use tablepro_core::TableRef;

    use super::*;
    use crate::test_support::{test_runtime, wait_until};

    fn table(name: &str) -> Candidate {
        Candidate::new(ProposalKind::Table, name, name)
    }

    fn column(name: &str) -> Candidate {
        Candidate::new(
            ProposalKind::Column {
                data_type: "integer".to_owned(),
                table: TableRef::unqualified("users"),
            },
            name,
            name,
        )
    }

    fn labels(list: &ProposalList) -> Vec<String> {
        (0..list.n_items())
            .filter_map(|at| list.item(at).and_downcast::<SqlProposal>())
            .map(|proposal| proposal.label().to_owned())
            .collect()
    }

    fn list(candidates: Vec<Candidate>, tasks: Option<Tasks>) -> ProposalList {
        ProposalList::new(Ranking::new(candidates.into(), ""), tasks)
    }

    #[test]
    fn closer_matches_rank_first_then_by_kind_then_in_catalog_order() {
        let candidates: Arc<[Candidate]> = vec![
            Candidate::keyword("USING"),
            table("product_status"),
            table("users"),
            column("user_id"),
            column("status"),
        ]
        .into();

        let order = |needle: &str| Ranking::new(candidates.clone(), &fuzzy::casefold(needle)).ranked;

        assert_eq!(order("us"), [2, 3, 0, 4, 1]);
        assert_eq!(
            order(""),
            [3, 4, 1, 2, 0],
            "nothing typed ranks by kind, then catalog order"
        );
        assert_eq!(order("zz"), Vec::<u32>::new());
    }

    #[gtk4::test]
    fn a_word_typed_further_narrows_in_one_change() {
        let list = list(vec![table("users"), table("orders"), table("user_log")], None);
        let seen = Rc::new(RefCell::new(Vec::new()));
        let log = seen.clone();
        list.connect_items_changed(move |_, position, removed, added| {
            log.borrow_mut().push((position, removed, added));
        });

        list.set_needle("u");
        list.set_needle("us");
        list.set_needle("user");
        list.set_needle("user_");
        list.set_needle("o");

        assert_eq!(labels(&list), ["orders", "user_log"]);
        assert_eq!(*seen.borrow(), [(0, 3, 2), (0, 2, 1), (0, 1, 2)]);
    }

    #[gtk4::test]
    fn the_ranking_for_the_last_word_typed_lands_off_the_gtk_thread() {
        let runtime = test_runtime();
        let names: Vec<Candidate> = (0..20_000).map(|at| table(&format!("t{at:05}"))).collect();
        let list = list(names, Some(runtime.tasks()));

        list.set_needle("t1");
        list.set_needle("t19");
        list.set_needle("t19999");

        assert_eq!(list.n_items(), 20_000, "the GTK thread ranked a word");
        wait_until(Duration::from_secs(10), || list.n_items() == 1).expect("the last word's ranking");
        assert_eq!(labels(&list), ["t19999"]);
    }

    #[gtk4::test]
    fn a_row_is_made_once_and_only_when_asked_for() {
        let names: Vec<Candidate> = (0..50_000).map(|at| table(&format!("t{at:05}"))).collect();
        let list = list(names, None);

        let first = list.item(0);

        assert_eq!(list.n_items(), 50_000);
        assert_eq!(list.imp().proposals.borrow().len(), 1);
        assert_eq!(list.item(0), first);
        assert_eq!(list.item(50_000), None);
    }
}
