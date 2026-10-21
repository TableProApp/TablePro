use std::cell::{Cell, OnceCell, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

use gtk4::gio;
use gtk4::glib;
use gtk4::prelude::*;
use gtk4::subclass::prelude::*;
use tablepro_session::runtime::Tasks;

use super::proposal_list::Candidate;
use super::sql_proposal::SqlProposal;

pub struct ProposalList {
    pub(super) candidates: RefCell<Arc<[Candidate]>>,
    /// The candidates the word matches, closest first.
    pub(super) ranked: RefCell<Vec<u32>>,
    /// The casefolded word typed last.
    pub(super) needle: RefCell<String>,
    /// The rows made so far, by candidate.
    pub(super) proposals: RefCell<HashMap<u32, SqlProposal>>,
    pub(super) tasks: OnceCell<Tasks>,
    /// Counts the words typed, so a ranking for an older one is dropped.
    pub(super) generation: Cell<u64>,
}

impl Default for ProposalList {
    fn default() -> Self {
        Self {
            candidates: RefCell::new(Arc::from([])),
            ranked: RefCell::default(),
            needle: RefCell::default(),
            proposals: RefCell::default(),
            tasks: OnceCell::new(),
            generation: Cell::new(0),
        }
    }
}

#[glib::object_subclass]
impl ObjectSubclass for ProposalList {
    const NAME: &'static str = "TableProProposalList";
    type Type = super::proposal_list::ProposalList;
    type Interfaces = (gio::ListModel,);
}

impl ObjectImpl for ProposalList {}

impl ListModelImpl for ProposalList {
    fn item_type(&self) -> glib::Type {
        SqlProposal::static_type()
    }

    fn n_items(&self) -> u32 {
        u32::try_from(self.ranked.borrow().len()).unwrap_or(u32::MAX)
    }

    fn item(&self, position: u32) -> Option<glib::Object> {
        let candidate = *self.ranked.borrow().get(position as usize)?;
        if let Some(proposal) = self.proposals.borrow().get(&candidate) {
            return Some(proposal.clone().upcast());
        }
        let proposal = self.candidates.borrow().get(candidate as usize)?.proposal();
        self.proposals.borrow_mut().insert(candidate, proposal.clone());
        Some(proposal.upcast())
    }
}
